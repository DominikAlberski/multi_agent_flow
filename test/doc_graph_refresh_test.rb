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

  def commit(message, name, content, dir = @dir)
    File.write(File.join(dir, name), content)
    system("git", "-C", dir, "add", name, out: File::NULL, err: File::NULL, exception: true)
    system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t",
           "commit", "-q", "-m", message, out: File::NULL, err: File::NULL, exception: true)
  end

  def write_stub
    File.write(File.join(@bin, "graphify"), <<~RUBY)
      #!/usr/bin/env ruby
      require "fileutils"
      File.open(ENV.fetch("CALLS"), "a") { |io| io.puts(ARGV.join(" ")) }
      exit 1 if ARGV.first == "extract" && ENV["STUB_FAIL"] == "1"
      if ARGV.first == "extract"
        out = ARGV[ARGV.index("--out") + 1]
        File.open(ENV.fetch("CALLS"), "a") { |io| io.puts("seeded") } if File.exist?(File.join(out, "graphify-out", "graph.json"))
        cached = File.exist?(File.join(out, "graphify-out", "cache", "seeded.txt"))
        File.open(ENV.fetch("CALLS"), "a") { |io| io.puts("cached=\#{cached}") }
        FileUtils.mkdir_p(File.join(out, "graphify-out"))
        File.write(File.join(out, "graphify-out", "graph.json"), ENV.fetch("STUB_GRAPH", "{}"))
      end
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, "graphify"))
  end

  def run_script(event, extra = {}, dir = @dir)
    env = { "PATH" => "#{@bin}:#{ENV.fetch("PATH", "")}", "CALLS" => @calls,
            "GEMINI_API_KEY" => "test" }.merge(extra)
    Open3.capture2e(env, RbConfig.ruby, SCRIPT, event, chdir: dir)
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

  # The build reuses the current graph as its cache. Without the seed every
  # markdown commit re-extracts the whole corpus.
  def test_the_build_is_seeded_with_the_current_graph
    FileUtils.mkdir_p(File.dirname(graph))
    File.write(graph, "OLD")
    commit("doc", "doc.md", "hello")

    run_script("post-commit")

    assert_includes calls, "seeded"
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

  # Defect 1: a hook in a worktree extracts the worktree tree and writes the
  # shared graph in the main checkout.
  def test_a_worktree_hook_writes_the_main_graph
    commit("doc", "doc.md", "hello")
    tree = File.join(@dir, "wt")
    system("git", "-C", @dir, "worktree", "add", "-q", tree, out: File::NULL, err: File::NULL, exception: true)
    commit("wt doc", "note.md", "worktree text", tree)

    out, status = run_script("post-commit", {}, tree)

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "extract #{File.realpath(tree)}"
    assert_equal "{}", File.read(graph)
  end

  # Defect 3: the main cache is passed on to the extract in the temp out dir.
  def test_the_cache_dir_is_passed_to_extract
    seed = File.join(@dir, "graphify-out", "cache", "seeded.txt")
    FileUtils.mkdir_p(File.dirname(seed))
    File.write(seed, "keep")
    commit("doc", "doc.md", "hello")

    out, status = run_script("post-commit")

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "cached=true"
    assert_equal "keep", File.read(seed)
  end

  # Defect 2: a second run that finds the lock held writes its tree to the
  # pending file. The holder drains that tree, so the change is not lost.
  def test_a_second_run_is_serialised_and_not_lost
    load SCRIPT
    dir = @dir
    calls = []
    pending = File.join(dir, "coordination", "doc-graph.pending")
    DocGraph.singleton_class.define_method(:markdown?) { |_event| true }
    DocGraph.define_singleton_method(:toplevel) { "#{dir}/tree-1" }
    DocGraph.define_singleton_method(:main) { dir }
    DocGraph::Refresh.define_singleton_method(:run) do |tree|
      calls << tree
      File.write(pending, "#{dir}/tree-2\n") if calls == ["#{dir}/tree-1"]
    end
    ENV["GEMINI_API_KEY"] = "test"

    DocGraph.run("post-commit")

    assert_equal ["#{dir}/tree-1", "#{dir}/tree-2"], calls
    refute File.exist?(pending)
    refute File.exist?(File.join(dir, "coordination", "doc-graph.lock"))
  end

  # Defect 2: a mark that lands while the holder releases the lock is not lost.
  # The holder takes the lock again and extracts the pending tree.
  def test_a_mark_written_during_release_is_not_lost
    load SCRIPT
    dir = @dir
    calls = []
    released = 0
    pending = File.join(dir, "coordination", "doc-graph.pending")
    DocGraph.singleton_class.define_method(:ready?) { |_event| true }
    DocGraph.define_singleton_method(:toplevel) { "#{dir}/tree-1" }
    DocGraph.define_singleton_method(:main) { dir }
    FileUtils.mkdir_p(File.dirname(pending))
    DocGraph::Lock.define_singleton_method(:acquire) { true }
    DocGraph::Lock.define_singleton_method(:release) do
      released += 1
      File.write(pending, "#{dir}/late\n") if released == 1
    end
    DocGraph::Refresh.define_singleton_method(:run) { |tree| calls << tree }

    DocGraph.run("post-commit")

    assert_equal ["#{dir}/tree-1", "#{dir}/late"], calls
    refute File.exist?(pending)
  end
end
