#!/usr/bin/env ruby
# frozen_string_literal: true

# test/steward_test.rb - steward runs only the listed operations, with checked arguments.
#
# Run: ruby test/steward_test.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "board_guard"

load File.expand_path("../assets/steward", __dir__)
load File.expand_path("../assets/coord", __dir__)

class StewardTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("steward-test"))
    @home = Dir.pwd
    Dir.chdir(@dir)
    register_tester
  end

  def register_tester
    FileUtils.mkdir_p([".maf/coordination", ".maf/worktrees/tester-bot"])
    dir = File.join(@dir, ".maf/worktrees/tester-bot")
    workers("tester-bot" => { "role" => "tester", "worker_id" => "bot", "dir" => dir })
  end

  def teardown
    Dir.chdir(@home)
    FileUtils.remove_entry(@dir)
  end

  def workers(data) = File.write(".maf/coordination/workers.json", JSON.generate(data))
  def refused(name, arg = nil) = assert_raises(Steward::Refused) { Steward::Ops.argv(name, arg) }.message

  def test_a_worker_restart_names_the_checked_worker
    assert_equal %w[maf worker restart tester-bot], Steward::Ops.argv("worker-restart", "tester-bot")
  end

  def test_a_worktree_sync_uses_the_role_and_the_id_of_the_registry
    assert_equal %w[worktree tester bot], Steward::Ops.argv("worktree-sync", "tester-bot").last(3)
  end

  def test_an_unknown_operation_is_refused
    assert_includes refused("shell", "rm -rf /"), "unknown operation shell"
  end

  def test_a_worker_outside_the_worktrees_is_refused
    workers("evil" => { "role" => "tester", "worker_id" => "x", "dir" => Dir.tmpdir })
    assert_includes refused("worker-restart", "evil"), "outside"
  end

  def test_an_unknown_worker_is_refused
    assert_includes refused("worker-retire", "nobody"), "no worker nobody"
  end

  def test_a_goal_id_must_be_eight_hex_characters
    assert_includes refused("goal-sync", "abc; rm -rf /"), "8 hex characters"
  end

  def test_runtime_restore_takes_no_argument
    assert_includes refused("runtime-restore", "--force"), "no argument"
  end

  def request(name, arg = nil)
    path = ".maf/coordination/ops/done/1.json"
    FileUtils.mkdir_p(File.dirname(path))
    { "id" => "1", "op" => name, "arg" => arg, "role" => "", "path" => path }
  end

  def handle(req, result: [true, "ok\n"], limit: Steward::Limit.new(File.join(@dir, "history.jsonl")))
    calls = []
    runner = ->(argv, _timeout) { (calls << argv) && result }
    Steward::Handler.new(req, runner: runner, limit: limit).run
    calls
  end

  def test_the_handler_runs_the_operation_and_records_the_result
    calls = handle(request("worker-restart", "tester-bot"))

    assert_equal [%w[maf worker restart tester-bot]], calls
    assert JSON.parse(File.read(".maf/coordination/ops/done/1.json"))["ok"]
    assert_includes File.read(".maf/coordination/events.log"), "worker-restart tester-bot: done"
  end

  def test_a_refused_request_runs_nothing
    calls = handle(request("worker-restart", "nobody"))

    assert_empty calls
    assert_includes File.read(".maf/coordination/events.log"), "refused: no worker nobody"
  end

  def test_the_fourth_run_in_an_hour_is_refused
    limit = Steward::Limit.new(File.join(@dir, "history.jsonl"))
    3.times { handle(request("worker-restart", "tester-bot"), limit: limit) }

    assert_empty handle(request("worker-restart", "tester-bot"), limit: limit)
    assert_includes File.read(".maf/coordination/events.log"), "ran 3 times in the last hour"
  end

  def test_the_queue_moves_a_request_out_before_it_runs
    write_request("a.json", "op" => "runtime-restore")
    seen = []
    Steward::Queue.new(".maf/coordination/ops").each_request { |req| seen << req["op"] }

    assert_equal ["runtime-restore"], seen
    assert_empty Dir.glob(".maf/coordination/ops/requests/*.json")
  end

  def write_request(name, data)
    FileUtils.mkdir_p(".maf/coordination/ops/requests")
    File.write(File.join(".maf/coordination/ops/requests", name), JSON.generate(data))
  end

  def test_the_runner_returns_the_output_and_stops_at_the_timeout
    assert_equal [true, "hi\n"], Steward::Runner.call([RbConfig.ruby, "-e", "puts 'hi'"], 5)
    refute Steward::Runner.call([RbConfig.ruby, "-e", "sleep 10"], 0.5).first
  end

  def test_steward_does_not_start_in_the_sandbox
    ENV["MAF_SEATBELT"] = "1"
    assert_raises(SystemExit) { capture_io { Steward::Daemon.start } }
  ensure
    ENV.delete("MAF_SEATBELT")
  end

  def test_coord_op_request_writes_a_request_for_steward
    env = { "COORD_DIR" => File.join(@dir, ".maf/coordination"), "COORD_ROLE" => "architect",
            "COORD_WORKER" => "architect-bot", "TASKRC" => File.join(@dir, "taskrc") }
    capture_io { Coord::CLI.new(%w[op request worker-restart tester-bot], env: env).run }
    request = JSON.parse(File.read(Dir.glob(".maf/coordination/ops/requests/*.json").first))

    assert_equal %w[worker-restart tester-bot architect], request.values_at("op", "arg", "role")
  end
end
