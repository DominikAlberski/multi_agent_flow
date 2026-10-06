# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../assets/harness-hooks/session-guard"

class HookSessionCase < Minitest::Test
  HOOK = File.expand_path("../assets/harness-hooks/next-task.rb", __dir__)
  UUID = "01234567-89ab-cdef-0123-456789abcdef"

  def setup
    @root = Dir.mktmpdir("maf-hook-session")
    prepare_paths
    prepare_files
    register
  end

  def prepare_paths
    @dir = File.join(@root, ".maf/worktrees/tester-1")
    @board = File.join(@root, ".maf/coordination")
    @marker = File.join(@root, "board-read")
  end

  def teardown = FileUtils.remove_entry(@root)

  def prepare_files
    FileUtils.mkdir_p([@dir, @board, File.join(@root, ".maf/bin")])
    File.write(File.join(@board, "taskrc"), "")
    File.write(File.join(@root, ".maf/bin/coord"), "File.write(#{@marker.inspect}, 'read'); puts #{UUID.inspect}\n")
    FileUtils.chmod("+x", File.join(@root, ".maf/bin/coord"))
  end

  def register
    @env = { "COORD_ROLE" => "tester", "COORD_WORKER" => "tester-1", "COORD_DIR" => @board,
             "TASKRC" => File.join(@board, "taskrc"), "COORD_DISPATCHED" => nil }
    Dir.chdir(@dir) { MafSession.register(@root, "codex", @env) }
  end

  def input(event = "Stop", id = "maf-session")
    { "session_id" => id, "hook_event_name" => event, "cwd" => @dir }
  end

  def run_hook(env = @env, payload = input, dir = @dir)
    Open3.capture3(env, RbConfig.ruby, HOOK, stdin_data: JSON.generate(payload), chdir: dir)
  end

  def bind_session
    out, err, status = run_hook(@env, input("SessionStart"))
    assert status.success?, err
    assert_empty out
    refute File.exist?(@marker)
  end

  def assert_inactive(env = @env, payload = input, dir = @dir)
    out, err, status = run_hook(env, payload, dir)
    assert status.success?, err
    assert_empty out
    refute File.exist?(@marker)
  end

  def assert_active(env = @env, payload = input, dir = @dir)
    out, err, status = run_hook(env, payload, dir)
    assert status.success?, err
    assert_equal "block", JSON.parse(out).fetch("decision")
    assert File.exist?(@marker)
  end

  def change_registration(fields)
    path = MafSession.path(@root, @env.fetch("MAF_SESSION_TOKEN"))
    data = JSON.parse(File.read(path)).merge(fields)
    File.write(path, JSON.generate(data))
  end

  def with_parent_tree
    original = MafSession::ProcessOwner.method(:parents)
    MafSession::ProcessOwner.define_singleton_method(:parents) { { Process.ppid => 1 } }
    yield
  ensure
    MafSession::ProcessOwner.define_singleton_method(:parents, original)
  end
end

class HookSessionTest < HookSessionCase

  def test_registered_session_reads_its_board
    bind_session
    assert_active
  end

  def test_role_and_board_environment_without_registration_does_nothing
    assert_inactive(@env.merge("MAF_SESSION_TOKEN" => nil))
  end

  def test_registered_environment_in_another_project_does_not_read_the_board
    bind_session
    other = File.join(@root, "other-project")
    FileUtils.mkdir_p(other)
    assert_inactive(@env, input.merge("cwd" => other), other)
  end

  def test_independent_session_in_the_main_checkout_does_nothing
    bind_session
    assert_inactive(@env, input.merge("cwd" => @root), @root)
  end

  def test_independent_session_in_the_same_worktree_does_nothing
    bind_session
    assert_inactive(@env, input("Stop", "independent-session"))
  end

  # Regression: /clear starts a new harness session. The first bound ID blocked it forever.
  def test_a_new_session_start_replaces_the_bound_session
    bind_session
    out, err, status = run_hook(@env, input("SessionStart", "after-clear"))
    assert status.success?, err
    assert_empty out
    assert_inactive
    assert_active(@env, input("Stop", "after-clear"))
  end

  def test_stop_without_session_start_does_nothing
    assert_inactive
  end

  def test_wrong_worker_does_nothing
    bind_session
    assert_inactive(@env.merge("COORD_WORKER" => "tester-2"))
  end

  def test_sibling_process_cannot_reuse_a_registered_token
    change_registration("pid" => 999_999)
    @env["COORD_SESSION_PID"] = "999999"
    with_parent_tree do
      Dir.chdir(@dir) { refute MafSession::Guard.new(@env, input("SessionStart")).authorized? }
    end
  end

  def test_external_taskrc_does_nothing
    bind_session
    path = File.join(@root, "other-taskrc")
    File.write(path, "")
    assert_inactive(@env.merge("TASKRC" => path))
  end

  def test_dispatcher_does_not_start_another_work_loop
    bind_session
    assert_inactive(@env.merge("COORD_DISPATCHED" => "1"))
  end

  def test_missing_or_invalid_payload_does_nothing
    assert_inactive(@env, {})
    out, err, status = Open3.capture3(@env, RbConfig.ruby, HOOK, stdin_data: "broken", chdir: @dir)
    assert status.success?, err
    assert_empty out
  end

  def test_corrupt_registration_does_nothing
    File.write(MafSession.path(@root, @env.fetch("MAF_SESSION_TOKEN")), "{}")
    assert_inactive
  end

  def test_descendant_directory_uses_the_registered_session
    bind_session
    dir = File.join(@dir, "src")
    FileUtils.mkdir_p(dir)
    assert_active(@env, input.merge("cwd" => dir), dir)
  end

  def test_process_ownership_requires_a_launch_ancestor
    refute MafSession::ProcessOwner.includes?(10, 20, { 10 => 1, 20 => 1 })
    assert MafSession::ProcessOwner.includes?(10, 20, { 10 => 15, 15 => 20, 20 => 1 })
  end
end

class BoardWatcherIsolationTest < HookSessionCase
  BOARD_HOOK = File.expand_path("../assets/harness-hooks/board-watch.rb", __dir__)

  def run_hook(env = @env, payload = input, dir = @dir)
    Open3.capture3(env, RbConfig.ruby, BOARD_HOOK, "--once", stdin_data: JSON.generate(payload), chdir: dir)
  end

  def test_independent_session_cannot_query_the_board_watcher
    assert_inactive(@env.merge("MAF_SESSION_TOKEN" => nil))
  end

  def test_another_project_cannot_query_the_board_watcher
    bind_session
    assert_inactive(@env, input.merge("cwd" => @root), @root)
  end

  def test_registered_board_watcher_still_pokes
    bind_session
    out, err, status = run_hook
    assert_equal 2, status.exitstatus, err
    assert_includes out, "role tester"
    assert File.exist?(@marker)
  end

  def test_another_harness_session_cannot_query_the_board_watcher
    bind_session
    assert_inactive(@env, input("Stop", "independent-session"))
  end
end

class HermesHookIsolationTest < HookSessionCase
  HERMES_HOOK = File.expand_path("../assets/harness-hooks/next-task-hermes.sh", __dir__)
  FAKE_HERMES = <<~RUBY
    #!#{RbConfig.ruby}
    require "json"
    File.write(ENV.fetch("HERMES_LOG"), JSON.generate(args: ARGV, token: ENV["MAF_SESSION_TOKEN"]))
  RUBY

  def run_hook(env = @env, payload = input, dir = @dir)
    Open3.capture3(env, RbConfig.ruby, HERMES_HOOK, stdin_data: JSON.generate(payload), chdir: dir)
  end

  def hermes_log = File.join(@root, "hermes.log")

  def install_fake_hermes
    bin = File.join(@root, "fake-bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "hermes"), FAKE_HERMES)
    FileUtils.chmod("+x", File.join(bin, "hermes"))
    @env.merge!("PATH" => "#{bin}:#{ENV.fetch('PATH')}", "HERMES_LOG" => hermes_log)
  end

  def resumed
    deadline = Time.now + 5
    sleep 0.01 until File.file?(hermes_log) || Time.now >= deadline
    JSON.parse(File.read(hermes_log))
  end

  def start_hermes
    install_fake_hermes
    _, err, status = run_hook
    assert status.success?, err
  end

  def test_independent_hermes_session_cannot_query_the_board
    assert_inactive(@env.merge("MAF_SESSION_TOKEN" => nil))
  end

  def test_another_project_cannot_resume_hermes
    assert_inactive(@env, input.merge("cwd" => @root), @root)
  end

  def test_registered_hermes_resumes_with_a_new_launch_token
    start_hermes
    info = resumed
    assert_includes info.fetch("args").each_cons(2).to_a, ["--resume", "maf-session"]
    refute_equal @env.fetch("MAF_SESSION_TOKEN"), info.fetch("token")
    assert File.exist?(@marker)
  end
end

# After `coord await`, the stop hook waits for work outside the model.
class HookAwaitTest < HookSessionCase
  def arm(seconds)
    FileUtils.mkdir_p(File.join(@board, "locks"))
    File.write(arm_path, JSON.generate("role" => "tester", "until" => Time.now.to_i + seconds))
  end

  def arm_path = File.join(@board, "locks", "await-tester-1.json")
  def quiet_board = File.write(File.join(@root, ".maf/bin/coord"), "exit 0\n")
  def reason = JSON.parse(run_hook(@env.merge("MAF_AWAIT_TICK" => "0.1")).first).fetch("reason")

  def write_message(name)
    inbox = File.join(@board, "inbox", "tester")
    FileUtils.mkdir_p(inbox)
    File.write(File.join(inbox, name), "x")
  end

  def test_an_armed_hook_wakes_the_session_on_work
    bind_session
    arm(60)
    assert_includes reason, "Work arrived for role tester"
    refute File.exist?(arm_path), "the hook disarms itself"
  end

  def test_an_armed_hook_wakes_on_a_message
    bind_session
    quiet_board
    write_message("1.md")
    arm(60)
    assert_includes reason, "Work arrived"
  end

  def test_an_fyi_message_does_not_end_the_wait
    bind_session
    quiet_board
    write_message("1.fyi.md")
    arm(1)
    assert_includes reason, "No work arrived for role tester"
  end
end
