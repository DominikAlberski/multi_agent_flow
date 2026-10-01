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
    reader = Dashboard::Collector.new(Dashboard::Config.new(["--coord", @coord]))
    open_task = { "uuid" => "a", "annotations" => [{ "description" => "ESCALATED: no ameba" }] }
    plain_task = { "uuid" => "b", "annotations" => [{ "description" => "STATUS: done" }] }

    summary = reader.send(:task_summary, [open_task, plain_task])

    assert_equal ["a"], summary[:escalated].map { |t| t["uuid"] }
  end

  def test_token_usage_per_worker
    FileUtils.mkdir_p(File.join(@coord, "usage"))
    File.write(File.join(@coord, "usage", "tester-bot.json"), JSON.generate("input_tokens" => 5, "runs" => 1))
    File.write(File.join(@coord, "usage", "broken.json"), "{")
    tokens = Dashboard::Collector.new(Dashboard::Config.new(["--coord", @coord])).collect[:tokens]

    assert_equal({ "tester-bot" => { "input_tokens" => 5, "runs" => 1 }, "broken" => {} }, tokens)
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
