#!/usr/bin/env ruby
# frozen_string_literal: true

# test/board_watch_test.rb - tests for assets/hooks/board-watch.rb.
#
# Run: ruby test/board_watch_test.rb
#
# The tests use fake collaborators and a zero interval. They do not start
# Claude Code, so they do not prove that the asyncRewake poke wakes a session.
require "minitest/autorun"
require "tmpdir"
require "fileutils"

load File.expand_path("../assets/hooks/board-watch.rb", __dir__)

module BoardWatchTestHelpers
  def work(unclaimed: [], claimed: [], messages: []) = BoardWatch::Work.new(unclaimed, claimed, messages)

  # FakeOwner stays alive for a fixed number of checks.
  class FakeOwner
    def initialize(checks) = @checks = checks
    def alive? = (@checks -= 1) >= 0
  end

  FakeBoard = Struct.new(:work)
  FakeSession = Struct.new(:running?)
end

class WorkTest < Minitest::Test
  include BoardWatchTestHelpers

  def test_empty_work_has_nothing_to_do
    refute work.any?
  end

  def test_summary_lists_only_present_kinds
    summary = work(unclaimed: %w[a b], messages: %w[m]).summary

    assert_equal "- unclaimed tasks: 2\n- unread messages: 1", summary
  end
end

class BackoffTest < Minitest::Test
  include BoardWatchTestHelpers

  def setup
    @dir = Dir.mktmpdir("board-watch-backoff")
    @backoff = BoardWatch::Backoff.new(File.join(@dir, "w.watch.json"), 60)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_new_work_is_due
    assert @backoff.due?(work(unclaimed: %w[a]))
  end

  def test_unchanged_work_waits_and_the_delay_doubles
    2.times { @backoff.record(work(unclaimed: %w[a])) }

    refute @backoff.due?(work(unclaimed: %w[a]))
    assert_equal 120, JSON.parse(File.read(File.join(@dir, "w.watch.json")))["delay"]
  end

  def test_changed_work_is_due_at_once
    @backoff.record(work(unclaimed: %w[a]))

    assert @backoff.due?(work(unclaimed: %w[b]))
  end
end

class LockTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("board-watch-lock")
    @lock_dir = File.join(@dir, "locks", "board-watch-w.d")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_second_watcher_for_one_worker_is_refused
    assert BoardWatch::Lock.new(@lock_dir).acquire
    refute BoardWatch::Lock.new(@lock_dir).acquire
  end

  def test_stale_lock_is_taken_over
    FileUtils.mkdir_p(@lock_dir)
    File.write(File.join(@lock_dir, "pid"), dead_pid)

    assert BoardWatch::Lock.new(@lock_dir).acquire
  end

  def test_release_frees_the_lock
    lock = BoardWatch::Lock.new(@lock_dir)
    lock.acquire
    lock.release

    refute Dir.exist?(@lock_dir)
  end

  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end
end

class SessionTest < Minitest::Test
  def test_recent_transcript_means_running
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.jsonl")
      File.write(path, "{}")

      assert BoardWatch::Session.new(path, 120).running?
      refute BoardWatch::Session.new(path, 0).running?
    end
  end

  def test_missing_transcript_means_idle
    refute BoardWatch::Session.new(nil, 120).running?
  end
end

class WatcherTest < Minitest::Test
  include BoardWatchTestHelpers

  def setup
    @dir = Dir.mktmpdir("board-watch-watcher")
    @backoff = BoardWatch::Backoff.new(File.join(@dir, "w.watch.json"), 0)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def watcher(board_work, running: false, checks: 3)
    parts = BoardWatch::Parts.new(board: FakeBoard.new(board_work), session: FakeSession.new(running),
                                  owner: FakeOwner.new(checks), backoff: @backoff)
    BoardWatch::Watcher.new(parts, 0)
  end

  def test_idle_agent_with_work_is_poked
    assert_equal %w[a], watcher(work(unclaimed: %w[a])).wait_for_work.unclaimed
  end

  def test_running_agent_is_not_poked
    assert_nil watcher(work(unclaimed: %w[a]), running: true).wait_for_work
  end

  def test_idle_agent_without_work_is_not_poked
    assert_nil watcher(work).wait_for_work
  end
end

class MainTest < Minitest::Test
  def test_does_nothing_without_an_agent
    assert_equal 0, BoardWatch::Main.new({}, {}).run
  end

  def test_does_nothing_under_the_dispatcher
    env = { "COORD_AGENT" => "tester", "COORD_DISPATCHED" => "1" }

    assert_equal 0, BoardWatch::Main.new(env, {}).run
  end
end
