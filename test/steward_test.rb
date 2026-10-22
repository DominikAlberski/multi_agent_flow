#!/usr/bin/env ruby
# frozen_string_literal: true

# test/steward_test.rb - steward runs only the listed operations, with checked arguments.
#
# Run: ruby test/steward_test.rb
require_relative "steward_helper"

class StewardTest < Minitest::Test
  include StewardHelpers

  def test_a_worker_restart_names_the_checked_worker
    assert_equal %w[maf worker restart tester-bot], Steward::Ops.argv("worker-restart", ["tester-bot"])
  end

  def test_a_worktree_sync_uses_the_role_and_the_id_of_the_registry
    assert_equal %w[worktree tester bot], Steward::Ops.argv("worktree-sync", ["tester-bot"]).last(3)
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
    assert_includes refused("runtime-restore", "--force"), "takes 0 argument(s)"
  end

  def test_a_model_cannot_start_with_a_dash
    assert_includes refused("worker-model", "tester-bot", "--dispatch"), "a model is"
  end

  def test_a_model_change_replaces_the_worker_with_the_new_model
    argv = Steward::Ops.argv("worker-model", %w[tester-bot gpt-6.1-sol])
    assert_equal %w[prepare tester_bot --model gpt-6.1-sol --replace tester_bot], argv.values_at(1, 3..7)
  end

  def test_bundle_install_needs_a_lockfile
    assert_includes refused("bundle-install"), "no Gemfile.lock"
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
    with_env("MAF_SEATBELT", "1") { assert_raises(SystemExit) { capture_io { Steward::Daemon.start } } }
  end

  def test_coord_op_request_writes_a_request_for_steward
    env = { "COORD_DIR" => File.join(@dir, ".maf/coordination"), "COORD_ROLE" => "architect",
            "COORD_WORKER" => "architect-bot", "TASKRC" => File.join(@dir, "taskrc") }
    capture_io { Coord::CLI.new(%w[op request worker-restart tester-bot], env: env).run }
    request = JSON.parse(File.read(Dir.glob(".maf/coordination/ops/requests/*.json").first))

    assert_equal ["worker-restart", ["tester-bot"], "architect"], request.values_at("op", "args", "role")
  end
end
