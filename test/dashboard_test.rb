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
    @coord = File.join(@dir, "coordination")
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
