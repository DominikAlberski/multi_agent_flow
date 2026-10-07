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
    write("presence", "pid" => pid, "started" => Maf::WorkerControl.started_at(pid))
    pid
  end

  def write(dir, data)
    FileUtils.mkdir_p(File.join(@coord, dir))
    File.write(File.join(@coord, dir, "architect-1.json"), JSON.generate(data))
  end

  def control(action, force: false)
    capture_io { Maf::WorkerControl.new(@root, "architect_1", force: force).run(action) }
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

  def test_stop_ends_a_dispatcher
    register(dispatch: true)
    pid = spawn_worker
    control("stop")

    refute Maf::RunningProcesses.alive?(pid)
  end

  def test_an_interactive_worker_in_a_turn_is_not_stopped
    register(dispatch: false)
    pid = spawn_worker
    transcript = File.join(@root, "t.jsonl")
    File.write(transcript, "{}")
    write("status", "transcript" => transcript)

    assert_raises(SystemExit) { control("stop") }
    assert Maf::RunningProcesses.alive?(pid)
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
    assert Maf::RunningProcesses.alive?(pid)
    control("stop", force: true)
    refute Maf::RunningProcesses.alive?(pid)
  end

  def test_an_idle_interactive_worker_stops_and_gets_the_start_command
    register(dispatch: false)
    pid = spawn_worker
    idle_transcript
    out, = control("restart")

    refute Maf::RunningProcesses.alive?(pid)
    assert_includes out, "maf start"
  end

  # A pid of a dead worker can belong to a new process later.
  def test_a_reused_pid_is_not_the_worker
    register(dispatch: true)
    write("presence", "pid" => Process.pid, "started" => "Mon Jan  1 00:00:00 2001")
    out, = control("status")

    assert_includes out, "stopped"
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
