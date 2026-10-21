#!/usr/bin/env ruby
# frozen_string_literal: true

# test/worker_list_test.rb - tests for maf worker list.
#
# Run: ruby test/worker_list_test.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/maf/worker_list"

class WorkerListTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("worker-list-test")
    @coord = File.join(@root, ".maf", "coordination")
    @pids = []
    %w[reviewer-1 tester-1].each { |worker| register(worker) }
  end

  def register(worker)
    Maf::Workers.at(@root).add(worker, "role" => worker.chomp("-1"), "harness" => "codex", "dispatch" => false)
  end

  def teardown
    @pids.each { |pid| kill(pid) }
    FileUtils.remove_entry(@root)
  end

  def kill(pid)
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end

  def spawn_process
    pid = spawn(RbConfig.ruby, "-e", "sleep 60")
    Process.detach(pid)
    @pids << pid
    sleep 0.2
    pid
  end

  def session(worker, pid)
    write("sessions", "#{worker}.maf.json", "worker" => worker, "role" => "reviewer", "harness" => "codex",
                                            "pid" => pid)
  end

  def dispatcher(worker, pid = spawn_process)
    write("presence", "#{worker}.json", "worker" => worker, "role" => "reviewer", "mode" => "dispatch", "pid" => pid,
                                        "started" => Maf::Shared::Processes.started_at(pid))
    pid
  end

  def write(dir, name, data)
    FileUtils.mkdir_p(File.join(@coord, dir))
    File.join(@coord, dir, name).tap { |path| File.write(path, JSON.generate(data)) }
  end

  def list = capture_io { Maf::WorkerList.new(@root).run }.first

  def test_a_worker_that_runs_as_a_session_and_a_dispatcher_shows_twice
    pids = { "session" => spawn_process, "dispatch" => dispatcher("reviewer-1") }
    session("reviewer-1", pids["session"])
    out = list

    pids.each { |mode, pid| assert_match(/^reviewer-1\s+reviewer\s+codex\s+#{mode}\s+#{pid}\s/, out) }
    assert_includes out, "warning: reviewer-1 runs 2 times"
  end

  def test_the_last_line_names_the_stopped_workers
    dispatcher("reviewer-1")

    assert_equal "stopped: tester-1", list.lines.last.chomp
  end

  def test_a_session_record_of_a_reused_pid_is_not_listed
    path = session("reviewer-1", spawn_process)
    File.utime(Time.now - 3600, Time.now - 3600, path)

    assert_equal "No worker runs.\nstopped: reviewer-1, tester-1\n", list
  end

  def test_a_dead_dispatcher_is_not_listed
    pid = spawn_process
    dispatcher("tester-1", pid)
    Process.kill("KILL", pid)
    sleep 0.2

    assert_equal "No worker runs.\nstopped: reviewer-1, tester-1\n", list
  end
end
