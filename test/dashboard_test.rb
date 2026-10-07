#!/usr/bin/env ruby
# frozen_string_literal: true

# test/dashboard_test.rb - tests for the data that assets/dashboard serves.
#
# Run: ruby test/dashboard_test.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
# `dashboard` has no .rb suffix, so `require` cannot find it.
load File.expand_path("../assets/dashboard", __dir__)

class DashboardCollectorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("dashboard-test")
    @coord = File.join(@dir, ".maf/coordination")
    FileUtils.mkdir_p(@coord)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def workers
    Dashboard::Collector.new(Dashboard::Config.new(["--coord", @coord])).collect[:workers]
  end

  def test_a_registered_worker_is_listed_without_tasks
    registry = { "frontend-developer-2" => { "role" => "frontend-developer", "harness" => "opencode" } }
    File.write(File.join(@coord, "workers.json"), JSON.generate(registry))

    assert_equal [["frontend-developer-2", "opencode"]], workers.map { |w| w.values_at("id", "harness") }
  end

  def test_a_worker_shows_its_last_event
    File.write(File.join(@coord, "workers.json"), JSON.generate("tester-1" => { "role" => "tester" }))
    File.write(File.join(@coord, "events.log"), "2026-09-26T10:00:00Z\tclaim\ttester-1\tabc\n")

    assert_equal "2026-09-26T10:00:00Z", workers.first["last_event"]
  end

def graph = Dashboard::Collector.new(Dashboard::Config.new(["--coord", @coord])).collect[:graph]

def test_the_graph_age_comes_from_the_vault_script
  FileUtils.mkdir_p(File.join(@dir, ".maf", "bin"))
  File.write(File.join(@dir, ".maf", "bin", "vault"), "puts '{\"state\":\"fresh\",\"commits\":0}'\n")

  assert_equal({ "state" => "fresh", "commits" => 0 }, graph)
end

def test_the_graph_age_is_nil_without_the_vault_script
  assert_nil graph
end

  def test_a_task_with_an_escalation_note_is_listed_as_escalated
    reader = Dashboard::TaskSummary.new(Dashboard::Config.new(["--coord", @coord]), [])
    open_task = { "uuid" => "a", "annotations" => [{ "description" => "ESCALATED: no ameba" }] }
    plain_task = { "uuid" => "b", "annotations" => [{ "description" => "STATUS: done" }] }

    summary = reader.of([open_task, plain_task])

    assert_equal ["a"], summary[:escalated].map { |t| t["uuid"] }
  end

  def test_a_goal_with_a_pull_request_is_listed_as_in_review
    reader = Dashboard::TaskSummary.new(Dashboard::Config.new(["--coord", @coord]), [])
    note = { "description" => "PR: https://github.com/o/r/pull/7" }
    goal = { "uuid" => "g", "role" => "goal", "annotations" => [note] }
    plain_goal = { "uuid" => "h", "role" => "goal" }

    summary = reader.of([goal, plain_goal])

    assert_equal ["g"], summary[:in_review].map { |t| t["uuid"] }
  end

  def test_a_broken_usage_file_counts_as_no_usage
    File.write(File.join(@coord, "workers.json"), JSON.generate("tester-bot" => { "role" => "tester" }))
    FileUtils.mkdir_p(File.join(@coord, "usage"))
    File.write(File.join(@coord, "usage", "tester-bot.json"), "{")

    assert_equal({}, workers.first["usage"])
  end

  def test_no_registry_means_no_workers
    assert_empty workers
  end
end

class DashboardBoardCheckTest < Minitest::Test
  def problem(*argv) = Dashboard::BoardCheck.new(Dashboard::Config.new(argv)).problem

  def test_a_missing_task_board_gives_an_error_that_names_the_fix
    Dir.mktmpdir("dashboard-check") do |dir|
      message = Dir.chdir(dir) { problem }

      assert_match(/no task board at .*\.maf\/coordination/, message)
      assert_match(/project root/, message)
    end
  end

  def test_an_existing_task_board_gives_no_error
    Dir.mktmpdir("dashboard-check") do |dir|
      FileUtils.touch(File.join(dir, "taskrc"))

      assert_nil problem("--coord", dir)
    end
  end

  def test_an_old_layout_project_gets_the_migrate_hint
    Dir.mktmpdir("dashboard-check") do |dir|
      FileUtils.mkdir_p(File.join(dir, "coordination"))
      FileUtils.touch(File.join(dir, "coordination", "taskrc"))

      assert_match(/maf migrate/, Dir.chdir(dir) { problem })
    end
  end
end

# The workers table shows every fact about a worker in one row.
class DashboardWorkerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("dashboard-worker")
    @coord = File.join(@dir, ".maf", "coordination")
    write("workers.json", "architect-1" => { "role" => "architect", "harness" => "claude", "dispatch" => true })
  end

  def teardown = FileUtils.remove_entry(@dir)

  def write(name, data)
    path = File.join(@coord, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, data.is_a?(String) ? data : JSON.generate(data))
  end

  def cfg(*argv) = Dashboard::Config.new(["--coord", @coord, *argv])
  def worker = Dashboard::Collector.new(cfg).collect[:workers].first

  def test_a_worker_row_holds_status_usage_log_and_last_action
    write("status/architect-1.json", "model" => "claude-opus-5-5", "running" => true)
    write("usage/architect-1.json", "input_tokens" => 10)
    write("sessions/architect-1.log", "one\ntwo\n")
    write("sessions/architect-1.control.log", "maf worker restart architect-1\n")

    assert_equal "claude-opus-5-5", worker.dig("status", "model")
    assert_equal 10, worker.dig("usage", "input_tokens")
    assert_equal %w[one two], worker["log"]
    assert_equal ["maf worker restart architect-1"], worker["action"]
  end

  def test_a_dead_pid_is_not_live
    write("presence/architect-1.json", "pid" => 999_999, "started" => "x")

    refute worker["live"]
  end

  def test_the_live_process_with_its_start_time_is_live
    started = Dashboard::WorkerReader.new(cfg).send(:started_at, Process.pid)
    write("presence/architect-1.json", "pid" => Process.pid, "started" => started)

    assert worker["live"]
  end

  def test_an_action_runs_maf_worker_in_the_background
    fake = File.join(@dir, "fake-maf")
    File.write(fake, "#!/bin/sh\necho \"args: $@\"\n")
    FileUtils.chmod(0o755, fake)

    assert_nil Dashboard::ActionRunner.new(cfg("--maf", fake)).run("architect-1", "restart")
    log = File.join(@coord, "sessions", "architect-1.control.log")
    30.times { break if File.read(log).include?("args:") || !sleep(0.1) }
    assert_includes File.read(log), "args: worker restart architect-1"
  end

  def test_a_restart_from_a_hint_passes_the_limit_flags
    fake = File.join(@dir, "fake-maf")
    File.write(fake, "#!/bin/sh\necho \"args: $@\"\n")
    FileUtils.chmod(0o755, fake)

    assert_nil Dashboard::ActionRunner.new(cfg("--maf", fake)).run("architect-1", "restart", "max_context" => 70_000)
    log = File.join(@coord, "sessions", "architect-1.control.log")
    30.times { break if File.read(log).include?("args:") || !sleep(0.1) }
    assert_includes File.read(log), "args: worker restart architect-1 --max-context 70000"
  end

  def test_an_action_refuses_an_unknown_or_a_non_number_limit
    runner = Dashboard::ActionRunner.new(cfg)

    assert_equal "unknown limit", runner.run("architect-1", "restart", "rm_rf" => 1)
    assert_equal "unknown limit", runner.run("architect-1", "restart", "max_context" => "1; rm")
  end

  def test_an_action_refuses_an_unknown_worker_or_action
    runner = Dashboard::ActionRunner.new(cfg)

    assert_match(/unknown worker/, runner.run("ghost-1", "stop"))
    assert_match(/unknown action/, runner.run("architect-1", "rm"))
  end

  Request = Struct.new(:request_method, :headers, :host) do
    def [](name) = headers[name]
  end

  # Another web site in the browser must not start an action.
  def test_an_action_needs_post_the_token_and_a_local_host
    server = Dashboard::Server.new(cfg)
    token = server.instance_variable_get(:@token)

    assert_equal "use POST", server.send(:refusal, Request.new("GET", { "X-Maf-Token" => token }, "localhost"))
    assert_equal "wrong token", server.send(:refusal, Request.new("POST", {}, "localhost"))
    assert_equal "wrong host", server.send(:refusal, Request.new("POST", { "X-Maf-Token" => token }, "evil.example"))
    assert_nil server.send(:refusal, Request.new("POST", { "X-Maf-Token" => token }, "127.0.0.1"))
  end

  Response = Struct.new(:status, :body)

  def test_the_page_and_the_data_need_a_local_host
    server = Dashboard::Server.new(cfg)
    foreign = Response.new(200, nil)
    server.send(:local, Request.new("GET", {}, "evil.example"), foreign) { flunk "served a foreign host" }

    assert_equal 403, foreign.status
    assert_equal :served, server.send(:local, Request.new("GET", {}, "localhost"), Response.new) { :served }
  end
end

# TokenHints turns the run history of a worker into hints. The numbers come
# from the TastingCompanion workers on 2026-10-07.
class TokenHintsTest < Minitest::Test
  LIMITS = { "max_context" => 150_000, "max_session_runs" => 5, "cache_window" => 3300 }.freeze
  WEDNESDAY_NOON = Time.utc(2026, 10, 7, 12)

  def run_line(session_run, input, context: nil, write: 0, limits: LIMITS, peak: nil)
    { "session_run" => session_run, "input_tokens" => input, "context" => context,
      "cache_write_input_tokens" => write, "limits" => limits, "peak" => peak }.compact
  end

  def hints(runs, now = WEDNESDAY_NOON) = Dashboard::TokenHints.new({ "id" => "w-bot", "runs" => runs }, now).list

  def frontend = [run_line(1, 486_907, context: 33_000), run_line(2, 2_408_342, context: 90_000),
                  run_line(3, 2_779_893, context: 120_000), run_line(4, 5_086_958, context: 164_833)]

  def test_a_growing_session_with_context_data_gets_a_context_cap
    hint = hints(frontend).first
    assert_equal({ "max_context" => 70_000 }, hint[:limits])
    assert_includes hint[:text], "a resumed run uses 5.7x the input of a fresh run (2.8M vs 487k)"
  end

  def test_a_growing_session_without_context_data_gets_fresh_runs
    runs = [run_line(1, 296_608), run_line(2, 753_704), run_line(3, 1_375_290), run_line(4, 1_821_822)]
    assert_equal({ "max_session_runs" => 1 }, hints(runs).first[:limits])
  end

  # A restart with the new limit starts a new history: the old runs no longer count.
  def test_runs_with_older_limits_do_not_count
    capped = LIMITS.merge("max_context" => 70_000)
    assert_empty hints(frontend + [run_line(1, 400_000, context: 30_000, limits: capped)])
  end

  def test_cheap_resumes_give_no_hint
    assert_empty hints([run_line(1, 300_000), run_line(2, 350_000), run_line(3, 400_000)])
  end

  def test_large_cache_writes_on_resumes_suggest_a_shorter_cache_window
    runs = [run_line(1, 100_000), run_line(2, 120_000, write: 60_000), run_line(3, 110_000, write: 50_000)]
    assert_equal({ "cache_window" => 1650 }, hints(runs).first[:limits])
  end

  def test_a_peak_rate_run_in_peak_hours_suggests_a_stop
    runs = [run_line(1, 100_000, peak: true)]
    hint = hints(runs, Time.utc(2026, 10, 7, 7, 30)).first
    assert_includes hint[:text], "until 10:00 UTC"
    assert_nil hint[:limits]
    assert_empty hints(runs, Time.utc(2026, 10, 7, 11))
  end
end
