#!/usr/bin/env ruby
# frozen_string_literal: true

# test/doc_graph_refresh_test.rb - tests for assets/doc-graph-refresh.
#
# Run: ruby test/doc_graph_refresh_test.rb
#
# The tests run the script as a subprocess against a disposable git repo. A
# stub `graphify` on PATH records every call and writes a fake graph. One test
# loads the script in-process to drive the lock and the pending flag.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
SCRIPT = File.join(ROOT, "assets", "doc-graph-refresh")

class DocGraphRefreshTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    @dir = File.realpath(Dir.mktmpdir("doc-graph-refresh-test"))
    @bin = File.join(@dir, "bin")
    @calls = File.join(@dir, "calls.log")
    FileUtils.mkdir_p(@bin)
    write_stub
    git("init", "-q")
    commit("init", "seed.txt", "seed\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(*args)
    system("git", "-C", @dir, *args, out: File::NULL, err: File::NULL, exception: true)
  end

  def commit(message, name, content)
    File.write(File.join(@dir, name), content)
    git("add", name)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
  end

  def write_stub
    File.write(File.join(@bin, "graphify"), <<~RUBY)
      #!/usr/bin/env ruby
      require "fileutils"
      File.open(ENV.fetch("CALLS"), "a") { |io| io.puts(ARGV.join(" ")) }
      exit 1 if ARGV.first == "extract" && ENV["STUB_FAIL"] == "1"
      if ARGV.first == "extract"
        out = ARGV[ARGV.index("--out") + 1]
        FileUtils.mkdir_p(File.join(out, "graphify-out"))
        File.write(File.join(out, "graphify-out", "graph.json"), ENV.fetch("STUB_GRAPH", "{}"))
      end
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, "graphify"))
  end

  def run_script(event, extra = {})
    env = { "PATH" => "#{@bin}:#{ENV.fetch("PATH", "")}", "CALLS" => @calls,
            "GEMINI_API_KEY" => "test" }.merge(extra)
    Open3.capture2e(env, RbConfig.ruby, SCRIPT, event, chdir: @dir)
  end

  def calls = File.exist?(@calls) ? File.read(@calls) : ""
  def graph = File.join(@dir, "graphify-out", "graph.json")
  def log = File.join(@dir, "coordination", "doc-graph.log")

  def test_no_call_without_a_markdown_change
    commit("text", "notes.txt", "no graph here")

    out, status = run_script("post-commit")

    assert_equal 0, status.exitstatus, out
    refute_includes calls, "extract"
    assert_includes File.read(log), "no markdown change"
  end

  def test_skips_without_a_gemini_key
    commit("doc", "doc.md", "hello")

    out, status = run_script("post-commit", "GEMINI_API_KEY" => "")

    assert_equal 0, status.exitstatus, out
    refute_includes calls, "extract"
    assert_includes File.read(log), "GEMINI_API_KEY"
  end

  def test_refreshes_the_graph_and_exports_after_a_markdown_change
    commit("doc", "doc.md", "hello")

    out, status = run_script("post-commit", "STUB_GRAPH" => "NEW")

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "extract"
    assert_includes calls, "export obsidian --dir obsidian"
    assert_equal "NEW", File.read(graph)
  end

  def test_a_failed_extract_keeps_the_old_graph
    FileUtils.mkdir_p(File.dirname(graph))
    File.write(graph, "OLD")
    commit("doc", "doc.md", "hello")

    out, status = run_script("post-commit", "STUB_FAIL" => "1")

    assert_equal 0, status.exitstatus, out
    assert_equal "OLD", File.read(graph)
    assert_includes File.read(log), "extract failed"
  end

  def test_post_merge_reads_orig_head_to_head
    commit("first", "one.md", "one")
    first = `git -C #{@dir} rev-parse HEAD`.strip
    commit("second", "two.md", "two")
    git("update-ref", "ORIG_HEAD", first)

    out, status = run_script("post-merge")

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "extract"
  end

  # A refresh that starts while the lock is held sets the pending flag. The
  # holder loops, so the second change is not lost.
  def test_a_second_run_is_serialised_and_not_lost
    load SCRIPT
    dir = @dir
    calls = 0
    DocGraph.singleton_class.define_method(:markdown?) { |_event| true }
    DocGraph.define_singleton_method(:main) { dir }
    DocGraph::Refresh.define_singleton_method(:run) do
      calls += 1
      FileUtils.touch(File.join(dir, "coordination", "doc-graph.pending")) if calls == 1
    end
    ENV["GEMINI_API_KEY"] = "test"

    DocGraph.run("post-commit")

    assert_equal 2, calls
    refute File.exist?(File.join(dir, "coordination", "doc-graph.pending"))
    refute File.exist?(File.join(dir, "coordination", "doc-graph.lock"))
  end
end
