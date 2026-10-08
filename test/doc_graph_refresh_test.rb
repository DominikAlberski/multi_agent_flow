#!/usr/bin/env ruby
# frozen_string_literal: true

# Run: ruby test/doc_graph_refresh_test.rb
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
            "GEMINI_API_KEY" => "test", "DOC_GRAPH_RETRY_WAIT" => "0" }.merge(extra)
    Open3.capture2e(env, RbConfig.ruby, SCRIPT, event, chdir: dir)
  end

  def calls = File.exist?(@calls) ? File.read(@calls) : ""
  def graph = File.join(@dir, "graphify-out", "graph.json")
  def log = File.join(@dir, ".maf/coordination", "doc-graph.log")

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
    assert_includes calls, "export obsidian --dir graphify-out/obsidian"
    assert_equal "NEW", File.read(graph)
  end

  # The swap replaces the derived files only. The saved notes and the vault
  # settings of the user stay in place, and the build does not get a copy.
  def test_the_refresh_keeps_the_memory_and_the_vault_folders
    kept = %w[memory/note.md obsidian/.obsidian/app.json].map { |name| File.join(File.dirname(graph), name) }
    kept.each do |file|
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "keep")
    end
    File.write(graph, "OLD")
    commit("doc", "doc.md", "hello")

    run_script("post-commit", "STUB_GRAPH" => "NEW")

    assert_equal "NEW", File.read(graph)
    kept.each { |file| assert_equal "keep", File.read(file), file }
  end

  # The new graph may lack a node of a lesson. reflect drops that lesson.
  def test_the_refresh_reflects_the_saved_notes_on_the_new_graph
    FileUtils.mkdir_p(File.join(File.dirname(graph), "memory"))
    commit("doc", "doc.md", "hello")

    run_script("post-commit", "STUB_GRAPH" => "NEW")

    dir = File.dirname(graph)
    assert_includes calls, "reflect --graph #{graph} --memory-dir #{dir}/memory --out #{dir}/reflections/LESSONS.md"
  end

  def test_no_reflect_without_saved_notes
    commit("doc", "doc.md", "hello")

    run_script("post-commit", "STUB_GRAPH" => "NEW")

    refute_includes calls, "reflect"
  end

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

  def test_the_extract_runs_the_chunks_one_at_a_time
    commit("doc", "doc.md", "hello")

    out, status = run_script("post-commit")

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "--max-concurrency 1"
  end

  def test_a_failed_extract_retries_at_most_three_times
    load SCRIPT
    attempts = 0
    DocGraph::Refresh.define_singleton_method(:extract_ok?) { |_tmp, _tree| attempts += 1; false }
    DocGraph::Refresh.define_singleton_method(:sleep) { |_seconds| }
    DocGraph::Log.define_singleton_method(:write) { |_message| }

    result = DocGraph::Refresh.build("/tmp/out", "/tmp/tree")

    refute result
    assert_equal 3, attempts
  end

  def test_a_second_run_is_serialised_and_not_lost
    load SCRIPT
    dir = @dir
    calls = []
    pending = File.join(dir, ".maf/coordination", "doc-graph.pending")
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
    refute File.exist?(File.join(dir, ".maf/coordination", "doc-graph.lock"))
  end

  def test_a_mark_written_during_release_is_not_lost
    load SCRIPT
    dir = @dir
    calls = []
    released = 0
    pending = File.join(dir, ".maf/coordination", "doc-graph.pending")
    DocGraph.singleton_class.define_method(:markdown?) { |_event| true }
    ENV["GEMINI_API_KEY"] = "test"
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

  def lock_dir = File.join(@dir, ".maf/coordination", "doc-graph.lock")
  def pending_file = File.join(@dir, ".maf/coordination", "doc-graph.pending")

  def stub_main
    load SCRIPT
    dir = @dir
    DocGraph.define_singleton_method(:main) { dir }
    FileUtils.mkdir_p(File.join(dir, ".maf/coordination"))
  end

  def test_a_lock_of_a_dead_process_is_broken
    stub_main
    FileUtils.mkdir_p(lock_dir)
    dead = Process.spawn("true").tap { |pid| Process.wait(pid) }
    File.write(File.join(lock_dir, "pid"), dead.to_s)

    assert DocGraph::Lock.acquire
    assert_equal Process.pid.to_s, File.read(File.join(lock_dir, "pid"))
  end

  def test_a_lock_older_than_the_ttl_is_broken
    stub_main
    FileUtils.mkdir_p(lock_dir)
    old = Time.now - DocGraph::Lock::TTL - 10
    File.utime(old, old, lock_dir)

    assert DocGraph::Lock.acquire
  end

  def test_a_lock_of_a_live_process_is_kept
    stub_main
    FileUtils.mkdir_p(lock_dir)
    File.write(File.join(lock_dir, "pid"), Process.pid.to_s)

    refute DocGraph::Lock.acquire
    assert File.directory?(lock_dir)
  end

  def test_the_holder_drains_each_unique_pending_tree
    stub_main
    trees = []
    DocGraph.define_singleton_method(:toplevel) { "one" }
    DocGraph::Refresh.define_singleton_method(:run) { |tree| trees << tree }
    File.write(pending_file, "two\nthree\ntwo\n")

    DocGraph.drain(["one"])

    assert_equal %w[one two three], trees
    refute File.exist?(pending_file)
  end

  def test_two_marked_trees_both_stay_in_the_pending_file
    stub_main
    %w[a b].each do |tree|
      DocGraph.define_singleton_method(:toplevel) { tree }
      DocGraph::Lock.mark_pending
    end

    assert_equal %w[a b], File.readlines(pending_file, chomp: true)
  end

  def test_the_pending_trees_stay_when_the_recheck_cannot_acquire
    stub_main
    File.write(pending_file, "late\n")
    DocGraph::Lock.define_singleton_method(:acquire) { false }

    DocGraph.recheck

    assert_equal "late\n", File.read(pending_file)
  end

  def test_a_merge_commit_triggers_a_refresh
    git("checkout", "-q", "-b", "side")
    commit("side doc", "side.md", "side")
    git("checkout", "-q", "-")
    commit("main file", "main.txt", "main")
    system("git", "-C", @dir, "-c", "user.name=t", "-c", "user.email=t@t", "merge", "--no-ff", "-q", "-m", "merge", "side",
           out: File::NULL, err: File::NULL, exception: true)

    out, status = run_script("post-commit")

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "extract"
  end

  def test_the_first_commit_triggers_a_refresh
    root = File.join(@dir, "root")
    FileUtils.mkdir_p(root)
    system("git", "-C", root, "init", "-q", exception: true)
    commit("doc", "doc.md", "hello", root)

    out, status = run_script("post-commit", {}, root)

    assert_equal 0, status.exitstatus, out
    assert_includes calls, "extract"
  end

  def test_the_vault_watcher_skips_update_while_the_refresh_lock_exists
    load File.join(ROOT, "assets", "vault")
    updates = []
    Vault::Daemon.define_singleton_method(:system) { |*args| updates << args }
    Vault::Daemon.define_singleton_method(:sleep) { |_seconds| }
    Dir.chdir(@dir) do
      FileUtils.mkdir_p(".maf/coordination/doc-graph.lock")
      Vault::Daemon.tick(nil)
      assert_empty updates
      FileUtils.rmdir(".maf/coordination/doc-graph.lock")
      Vault::Daemon.tick(nil)
    end

    assert_equal [%w[graphify update .]], updates
  end
end
