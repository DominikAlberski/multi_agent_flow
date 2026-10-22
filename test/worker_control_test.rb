#!/usr/bin/env ruby
# frozen_string_literal: true

# test/worker_control_test.rb - tests for maf worker stop|start|restart.
#
# Run: ruby test/worker_control_test.rb
#
# A sleeping child process plays the worker. Its presence record holds its
# pid and its start time, as coord and the dispatcher write them.
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/maf/setup_agent"
require_relative "../lib/maf/worker_control"

class WorkerControlTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("worker-control-test")
    @coord = File.join(@root, ".maf", "coordination")
    @pids = []
  end

  def teardown
    @pids.each { |pid| Process.kill("KILL", pid) rescue nil }
    FileUtils.remove_entry(@root)
  end

  def register(dispatch:)
    entry = { "role" => "architect", "worker_id" => "1", "harness" => "claude", "dispatch" => dispatch,
              "dir" => File.join(@root, ".maf", "worktrees", "architect-1") }
    Maf::Workers.at(@root).add("architect-1", entry)
  end

  def spawn_worker
    pid = spawn(RbConfig.ruby, "-e", "trap('TERM') { exit }; sleep 60")
    Process.detach(pid)
    @pids << pid
    sleep 0.2
    write("presence", "pid" => pid, "started" => Maf::Shared::Processes.started_at(pid))
    pid
  end

  def write(dir, data)
    FileUtils.mkdir_p(File.join(@coord, dir))
    File.write(File.join(@coord, dir, "architect-1.json"), JSON.generate(data))
  end

  def control(action, force: false)
    capture_io { Maf::WorkerControl.new(@root, "architect_1", force: force).run(action) }
  end

  def refused(action) = assert_raises(SystemExit) { control(action) }.message

  def test_a_role_with_one_worker_names_that_worker
    register(dispatch: true)
    out, = capture_io { Maf::WorkerControl.new(@root, "architect").run("status") }

    assert_equal "architect-1: stopped\n", out
  end

  def test_a_role_with_two_workers_needs_the_worker
    register(dispatch: true)
    Maf::Workers.at(@root).add("architect-2", "role" => "architect", "dispatch" => true)
    err = assert_raises(SystemExit) { capture_io { Maf::WorkerControl.new(@root, "architect") } }

    assert_includes err.message, "more than one worker: architect-1, architect-2"
  end

  def test_stop_of_a_stopped_worker_does_nothing
    register(dispatch: true)
    out, = control("stop")

    assert_includes out, "already stopped"
  end

  def test_start_of_a_live_worker_does_nothing
    register(dispatch: true)
    pid = spawn_worker
    out, = control("start")

    assert_includes out, "already runs (pid #{pid})"
  end

  def test_a_worker_without_a_start_time_stays_and_is_not_signaled
    register(dispatch: true)
    pid = spawn_worker
    write("presence", "pid" => pid, "seen_at" => Time.now.utc.iso8601)
    assert_includes control("start").first, "already runs (pid #{pid})"
    assert_includes refused("stop"), "Stop it with: kill #{pid}"
  end

  def test_stop_ends_a_dispatcher
    register(dispatch: true)
    pid = spawn_worker
    control("stop")

    refute Maf::Shared::Processes.alive?(pid)
  end

  def test_an_interactive_worker_in_a_turn_is_not_stopped
    register(dispatch: false)
    pid = spawn_worker
    transcript = File.join(@root, "t.jsonl")
    File.write(transcript, "{}")
    write("status", "transcript" => transcript)

    assert_raises(SystemExit) { control("stop") }
    assert Maf::Shared::Processes.alive?(pid)
  end

  def idle_transcript
    transcript = File.join(@root, "t.jsonl")
    File.write(transcript, "{}")
    File.utime(Time.now - 120, Time.now - 120, transcript)
    write("status", "transcript" => transcript)
  end

  # opencode has no transcript in the status. maf cannot tell if it is idle.
  def test_an_interactive_worker_with_an_unknown_state_needs_force
    register(dispatch: false)
    pid = spawn_worker

    assert_raises(SystemExit) { control("stop") }
    assert Maf::Shared::Processes.alive?(pid)
    control("stop", force: true)
    refute Maf::Shared::Processes.alive?(pid)
  end

  def test_an_idle_interactive_worker_stops_and_gets_the_start_command
    register(dispatch: false)
    pid = spawn_worker
    idle_transcript
    out, = control("restart")

    refute Maf::Shared::Processes.alive?(pid)
    assert_includes out, "maf start"
  end

  # The presence file can name an older session. maf start writes a session record for each session.
  def test_stop_finds_the_session_that_the_presence_file_misses
    register(dispatch: false)
    pid = spawn_worker
    write("presence", "pid" => 999_999, "started" => "")
    session_record(pid)
    control("stop", force: true)

    refute Maf::Shared::Processes.alive?(pid)
  end

  def test_a_session_that_does_not_stop_gets_the_kill_command
    register(dispatch: false)
    session_record(spawn_worker)
    message = never_exits { refused_with_force("stop") }

    assert_includes message, "kill -9"
  end

  def session_record(pid)
    FileUtils.mkdir_p(File.join(@coord, "sessions"))
    File.write(File.join(@coord, "sessions", "token.maf.json"),
               JSON.generate("worker" => "architect-1", "role" => "architect", "harness" => "claude", "pid" => pid))
  end

  def refused_with_force(action) = assert_raises(SystemExit) { control(action, force: true) }.message

  def never_exits
    original = Maf::RunningProcesses.method(:wait_for_exit)
    Maf::RunningProcesses.define_singleton_method(:wait_for_exit) { |*, **| false }
    yield
  ensure
    Maf::RunningProcesses.define_singleton_method(:wait_for_exit, original)
  end

  # A pid of a dead worker can belong to a new process later.
  def test_a_reused_pid_is_not_the_worker
    register(dispatch: true)
    write("presence", "pid" => Process.pid, "started" => "Mon Jan  1 00:00:00 2001")
    out, = control("status")

    assert_includes out, "stopped"
  end

  def test_restart_of_a_worker_with_an_unknown_pid_fails
    register(dispatch: true)
    write("presence", "pid" => Process.pid, "seen_at" => Time.now.utc.iso8601)
    assert_includes refused("restart"), "kill #{Process.pid}"
  end

  def test_an_empty_start_time_takes_the_start_time_of_the_presence
    Maf::Workers.at(@root).update("architect-1", "pid" => Process.pid, "started" => "")
    write("presence", "pid" => Process.pid, "started" => "Mon Jan  1 00:00:00 2001")
    assert_equal "Mon Jan  1 00:00:00 2001", Maf::Workers.at(@root).started("architect-1")
  end

  def test_a_dispatcher_without_a_start_time_runs_while_its_heartbeat_is_recent
    Maf::Workers.at(@root).update("architect-1", "pid" => Process.pid)
    write("presence", "pid" => Process.pid, "seen_at" => Time.now.utc.iso8601)
    assert Maf::Workers.at(@root).running?("architect-1")
  end

  def test_a_second_action_at_the_same_time_is_refused
    register(dispatch: true)
    FileUtils.mkdir_p(File.join(@coord, "locks", "control-architect-1.d"))

    assert_raises(SystemExit) { control("stop") }
  end

  # A killed command or a reboot leaves the lock behind.
  def test_an_old_lock_is_taken_over
    register(dispatch: true)
    lock = File.join(@coord, "locks", "control-architect-1.d")
    FileUtils.mkdir_p(lock)
    File.utime(Time.now - 7200, Time.now - 7200, lock)
    out, = control("status")

    assert_includes out, "stopped"
  end

  def test_the_lock_is_released_after_an_action
    register(dispatch: true)
    control("status")

    refute Dir.exist?(File.join(@coord, "locks", "control-architect-1.d"))
  end

  def test_terminate_of_a_process_of_another_user_aborts
    with_kill_stub(->(*) { raise Errno::EPERM }) do
      _, err = capture_io { assert_raises(SystemExit) { Maf::RunningProcesses.terminate(4242) } }
      assert_includes err, "sudo kill 4242"
    end
  end

  def with_kill_stub(stub)
    original = Process.method(:kill)
    Process.define_singleton_method(:kill, &stub)
    yield
  ensure
    Process.define_singleton_method(:kill, original)
  end

  def test_start_saves_the_session_limits_of_the_role
    register(dispatch: false)
    spawn_worker
    capture_io { Maf::WorkerControl.new(@root, "architect_1", limits: { "max_context" => 80_000 }).run("start") }

    saved = JSON.parse(File.read(File.join(@root, ".maf", "config.json")))
    assert_equal({ "architect" => { "max_context" => 80_000 } }, saved.dig("team", "limits"))
  end
end

class RoleLimitsTest < Minitest::Test
  def test_parse_reads_the_limit_flags
    args = %w[restart reviewer_bot --max-session-runs 1 --cache-window 120]
    assert_equal({ "max_session_runs" => 1, "cache_window" => 120 }, Maf::RoleLimits.parse(args))
  end

  def test_a_limit_needs_a_number
    assert_raises(SystemExit) { capture_io { Maf::RoleLimits.parse(%w[--max-context lots]) } }
  end

  def test_save_keeps_the_other_keys
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".maf"))
      path = File.join(root, ".maf", "config.json")
      team = { "limits" => { "reviewer" => { "cache_window" => 9 } } }
      File.write(path, JSON.generate("agents" => [1], "team" => team))
      capture_io { Maf::RoleLimits.new(root).save("reviewer", "max_context" => 5) }
      saved = JSON.parse(File.read(path))
      assert_equal [1], saved["agents"]
      assert_equal({ "cache_window" => 9, "max_context" => 5 }, saved.dig("team", "limits", "reviewer"))
    end
  end
end
