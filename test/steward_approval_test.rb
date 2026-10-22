#!/usr/bin/env ruby
# frozen_string_literal: true

# test/steward_approval_test.rb - steward runs, limits, parks, approves, and denies requests.
#
# Run: ruby test/steward_approval_test.rb
require_relative "steward_helper"

class StewardApprovalTest < Minitest::Test
  include StewardHelpers

  def pending = ".maf/coordination/ops/pending/#{ID}.json"

  def test_the_handler_runs_the_operation_and_records_the_result
    calls = handle(request("worker-restart", "tester-bot"))

    assert_equal [%w[maf worker restart tester-bot]], calls
    assert JSON.parse(File.read(".maf/coordination/ops/done/#{ID}.json"))["ok"]
    assert_includes events, "worker-restart tester-bot: done"
  end

  def test_a_refused_request_runs_nothing
    assert_empty handle(request("worker-restart", "nobody"))
    assert_includes events, "refused: no worker nobody"
  end

  def test_the_fourth_run_in_an_hour_is_refused
    limit = Steward::Limit.new(File.join(@dir, "history.jsonl"))
    3.times { handle(request("worker-restart", "tester-bot"), limit: limit) }

    assert_empty handle(request("worker-restart", "tester-bot"), limit: limit)
    assert_includes events, "ran 3 times in the last hour"
  end

  def test_an_approve_operation_waits_for_the_user
    assert_empty handle(request("worker-start", "tester-bot"))
    assert_path_exists pending
    assert_includes events, "maf op approve #{ID}"
  end

  def test_the_user_approves_a_waiting_operation
    handle(request("worker-start", "tester-bot"))
    calls = []
    with_runner(->(argv, _) { (calls << argv) && [true, "started"] }) { approvals("approve", ID) }

    assert_equal [%w[maf worker start tester-bot]], calls
    refute_path_exists pending
  end

  def approvals(*argv) = capture_io { Steward::Approvals.run(argv) }

  def with_runner(runner)
    original = Steward::Runner.method(:call)
    Steward::Runner.define_singleton_method(:call) { |*args| runner.call(*args) }
    yield
  ensure
    Steward::Runner.define_singleton_method(:call, original)
  end

  def test_the_user_denies_a_waiting_operation
    File.write("Gemfile.lock", "")
    handle(request("bundle-install"))
    approvals("deny", ID)

    assert_includes events, "denied by the user"
    refute_path_exists pending
  end

  def test_an_agent_cannot_approve
    with_env("COORD_ROLE", "project-manager") { assert_raises(SystemExit) { approvals("approve", ID) } }
  end

  def test_a_bad_request_id_is_refused
    assert_raises(SystemExit) { approvals("approve", "../../etc/passwd") }
  end

  def test_the_sandbox_policy_can_turn_an_operation_off_or_to_auto
    File.write(".maf/sandbox.json", JSON.generate("ops" => { "worker-restart" => "off", "worker-start" => "auto" }))

    assert_empty handle(request("worker-restart", "tester-bot"))
    assert_equal [%w[maf worker start tester-bot]], handle(request("worker-start", "tester-bot"))
  end
end
