#!/usr/bin/env ruby
# frozen_string_literal: true

# test/coord_test.rb - behavioral tests for assets/coord.
#
# Run: ruby test/coord_test.rb
#
# Scopes tests are pure and always run. Taskwarrior tests are real
# integration tests against a disposable, project-local task database (never
# the global ~/.task); they skip cleanly if `task` is not installed.
require "minitest/autorun"
require "tmpdir"
# `coord` has no .rb suffix (it's an installed executable), so `require` can't
# find it; `load` takes the literal path instead.
load File.expand_path("../assets/coord", __dir__)

class ScopesTest < Minitest::Test
  def test_prefix_overlap_is_detected
    assert Coord::Scopes.overlap?("src/**", "src/utils/**")
  end

  def test_disjoint_scopes_do_not_overlap
    refute Coord::Scopes.overlap?("src/queries/**", "src/models/**")
  end

  def test_exact_paths_do_not_false_positive_on_shared_prefix
    refute Coord::Scopes.overlap?("src/foo.rb", "src/foobar.rb")
  end
end

class TaskwarriorTest < Minitest::Test
  def setup
    skip "Taskwarrior ('task') not installed" unless Coord::TaskCli.new.available?

    @dir = Dir.mktmpdir("coord-test")
    coord_dir = File.join(@dir, "coordination")
    @env = { "COORD_DIR" => coord_dir, "TASKRC" => File.join(coord_dir, "taskrc"),
             "COORD_AGENT" => "backend-developer", "COORD_WORKER" => "backend-1" }
    Coord::CLI.new(["init"], env: @env).run
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def tasks = Coord::Tasks.new

  def add(title)
    tasks.add(title: title, agent: "backend-developer")
  end

  def find(id)
    Coord::Tasks.new.pending.find { |t| t["uuid"] == id }
  end

  # A title or annotation that happens to look like "attr:value" must survive
  # as literal text, not be parsed as a Taskwarrior attribute assignment.
  def test_attribute_shaped_title_survives_round_trip
    id = add("scope:auth due:tomorrow")
    assert_equal "scope:auth due:tomorrow", find(id)["description"]
    assert_nil find(id)["due"]
  end

  def test_annotate_with_attribute_shaped_text_stays_literal
    id = add("seed task")
    tasks.annotate(id, "priority:H not an attribute")
    assert_equal "priority:H not an attribute", find(id)["annotations"].first["description"]
    assert_nil find(id)["priority"]
  end

  def test_claim_refuses_a_second_worker
    id = add("task one")
    tasks.claim(id, "backend-1")
    error = assert_raises(Coord::Error) { Coord::Tasks.new.claim(id, "backend-2") }
    assert_match(/already claimed/, error.message)
  end

  def test_claim_force_steals_and_reports_prior_holder
    id = add("task two")
    tasks.claim(id, "backend-1")
    holder = Coord::Tasks.new.claim(id, "backend-2", force: true)
    assert_equal "backend-1", holder
  end

  def test_unclaim_frees_a_task_for_reclaim
    id = add("task three")
    tasks.claim(id, "backend-1")
    tasks.unclaim(id)
    assert_empty find(id)["worker"].to_s
    assert_nil find(id)["start"]
    assert_nil Coord::Tasks.new.claim(id, "backend-2")
  end

  def test_expired_lease_is_reclaimable_without_force
    id = add("task four")
    tasks.claim(id, "backend-1")
    stale = (Time.now - Coord::Lease.ttl - 10).utc.strftime("%Y%m%dT%H%M%SZ")
    system("task", "rc.confirmation=no", id, "modify", "start:#{stale}", out: File::NULL, err: File::NULL)
    holder = Coord::Tasks.new.claim(id, "backend-2")
    assert_equal "backend-1", holder
  end

  # Regression: `next --wait` used to re-query through the CLI-memoized Tasks
  # instance, freezing on the first (empty) snapshot forever; and `--timeout`,
  # parsed after the positional ROLE `shift`, was swallowed as the ROLE
  # argument instead of recognized as a flag.
  def test_next_wait_detects_a_task_added_during_the_wait
    Thread.new { sleep 0.3; add("arrives during wait") }
    out, = capture_io do
      Coord::CLI.new(["next", "--wait", "--interval", "1", "--timeout", "5"], env: @env).run
    end
    assert_match(/arrives during wait/, out)
  end

  def test_next_wait_times_out_cleanly_when_nothing_arrives
    error = assert_raises(SystemExit) do
      capture_io { Coord::CLI.new(["next", "--wait", "--interval", "1", "--timeout", "1"], env: @env).run }
    end
    assert_equal 1, error.status
  end

  # Regression: a failed `task add` used to return nil, so `coord add` printed
  # a blank line and exited 0 while creating nothing.
  def test_add_raises_when_taskwarrior_cannot_create_the_task
    blocker = File.join(@dir, "not-a-directory")
    File.write(blocker, "x")
    File.write(@env["TASKRC"], "data.location=#{blocker}\n")

    error = assert_raises(Coord::Error) do
      Coord::Tasks.new.add(title: "boom", agent: "backend-developer")
    end
    assert_match(/task add failed/, error.message)
  end

  def test_inbox_wait_with_no_positional_agent_still_recognizes_wait
    Thread.new { sleep 0.3; Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hi"], env: @env).run }
    out, = capture_io do
      Coord::CLI.new(["inbox", "--wait", "--interval", "1", "--timeout", "5"], env: @env).run
    end
    assert_match(/hi/, out)
  end
end

class TaskrcSafetyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("coord-taskrc-test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_ensure_taskrc_writes_data_location_for_its_own_project_local_file
    coord_dir = File.join(@dir, "coordination")
    taskrc = File.join(coord_dir, "taskrc")
    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    assert_match(/^data\.location=/, File.read(taskrc))
  end

  # Regression: a user's own TASKRC (e.g. ~/.taskrc, pointed at their real
  # Taskwarrior database) must never be rewritten to point at this project.
  def test_ensure_taskrc_refuses_to_redirect_an_external_taskrc
    coord_dir = File.join(@dir, "coordination")
    external_taskrc = File.join(@dir, "external", ".taskrc")
    FileUtils.mkdir_p(File.dirname(external_taskrc))
    File.write(external_taskrc, "# pre-existing personal config\n")

    capture_io { Coord::Setup.new(Coord::Paths.new(coord_dir), external_taskrc).ensure_taskrc }
    content = File.read(external_taskrc)

    refute_match(/^data\.location=/, content)
    assert_includes content, "# pre-existing personal config"
    assert_includes content, Coord::MARKER
  end

  # Regression: a marked taskrc from an older install that has no
  # data.location would silently fall back to the global ~/.task database.
  def test_ensure_taskrc_adds_data_location_to_an_old_marked_taskrc
    coord_dir = File.join(@dir, "coordination")
    taskrc = File.join(coord_dir, "taskrc")
    FileUtils.mkdir_p(coord_dir)
    File.write(taskrc, "# #{Coord::MARKER}\nuda.agent.type=string\n")

    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    content = File.read(taskrc)
    assert_match(/^data\.location=/, content)
    assert_includes content, "uda.agent.type=string"
    assert_equal 1, content.scan(Coord::MARKER).size
  end
end

class WorktreeTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = Dir.mktmpdir("coord-worktree-test")
    run_git("init", "-q")
    # `coordination/.../.gitkeep` and `coord` are normally tracked in git, so a
    # fresh worktree checks out its own real copies of them.
    FileUtils.mkdir_p(File.join(@root, "coordination", "exports"))
    FileUtils.touch(File.join(@root, "coordination", "exports", ".gitkeep"))
    FileUtils.touch(File.join(@root, "coord"))
    File.write(File.join(@root, ".gitignore"), "coord-env.sh\n")
    run_git("add", "coord", "coordination", ".gitignore")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
  end

  def teardown
    FileUtils.remove_entry(@root)
    FileUtils.remove_entry(worktrees_root) if Dir.exist?(worktrees_root)
  end

  def run_git(*args)
    system("git", "-C", @root, *args, out: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  # All worktrees live under one sibling folder, <project>.worktrees/<slug>.
  def worktrees_root
    File.join(File.dirname(@root), "#{File.basename(@root)}.worktrees")
  end

  def test_worktree_lives_under_the_worktrees_folder
    Coord::Worktree.new(@root).create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")
    env_file = File.read(File.join(@worktree_dir, "coord-env.sh"))

    assert_equal "#{@root}.worktrees/tester", @worktree_dir
    assert Dir.exist?(@worktree_dir)
    assert_includes env_file, "COORD_DIR=#{File.join(@root, "coordination")}"
    assert_includes env_file, "TASKRC=#{File.join(@root, "coordination", "taskrc")}"
  end

  # The tracked coord/coordination checked out into the worktree must be left
  # alone: a dirty worktree, or an absolute-path symlink some agent later
  # commits over them, is exactly the failure this design avoids.
  def test_worktree_leaves_tracked_files_untouched
    Coord::Worktree.new(@root).create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")
    status = `git -C #{@worktree_dir} status --porcelain`

    assert_empty status.strip
  end
end

# Regression: on a first run, `coord` and the flow's .gitignore block are not
# committed yet. `git worktree add` then brings neither, so the worktree had no
# ./coord and showed coord-env.sh as untracked. The command must copy coord in
# and keep coord-env.sh out of the worktree's status.
class WorktreeFirstRunTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = Dir.mktmpdir("coord-worktree-first")
    run_git("init", "-q")
    File.write(File.join(@root, "README.md"), "x\n")
    run_git("add", "README.md")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
    File.write(File.join(@root, "coord"), "#!/usr/bin/env ruby\n")
    @worktree_dir = File.join(File.dirname(@root), "#{File.basename(@root)}.worktrees", "tester")
  end

  def teardown
    FileUtils.remove_entry(@root)
    worktrees_root = File.dirname(@worktree_dir)
    FileUtils.remove_entry(worktrees_root) if Dir.exist?(worktrees_root)
  end

  def run_git(*args)
    system("git", "-C", @root, *args, out: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def test_worktree_copies_uncommitted_coord_and_hides_env_file
    Coord::Worktree.new(@root).create("tester", nil)

    assert File.exist?(File.join(@worktree_dir, "coord"))
    status = `git -C #{@worktree_dir} status --porcelain`
    refute_includes status, "coord-env.sh"
  end
end
