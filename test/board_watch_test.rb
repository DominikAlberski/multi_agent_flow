#!/usr/bin/env ruby
# frozen_string_literal: true

# test/board_watch_test.rb - tests for assets/harness-hooks/board-watch.rb.
#
# Run: ruby test/board_watch_test.rb
#
# The tests use fake collaborators and a zero interval. They do not start
# Claude Code, so they do not prove that the asyncRewake poke wakes a session.
require "minitest/autorun"
require "tmpdir"
require "fileutils"

load File.expand_path("../assets/harness-hooks/board-watch.rb", __dir__)

module BoardWatchTestHelpers
  def work(unclaimed: [], claimed: [], messages: []) = BoardWatch::Work.new(unclaimed, claimed, messages)

  # FakeOwner stays alive for a fixed number of checks.
  class FakeOwner
    def initialize(checks) = @checks = checks
    def alive? = (@checks -= 1) >= 0
  end

  # FakeBoard has messages of one age, in seconds.
  FakeBoard = Struct.new(:work, :message_age) do
    def settled?(work, batch) = !(work.unclaimed + work.claimed).empty? || message_age.to_i >= batch
  end
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

class BoardSettledTest < Minitest::Test
  include BoardWatchTestHelpers

  def test_the_age_of_the_oldest_message_decides
    Dir.mktmpdir("board-watch-settled") do |dir|
      inbox = File.join(dir, "inbox", "architect")
      FileUtils.mkdir_p(inbox)
      File.write(File.join(inbox, "1.md"), "x")
      board = BoardWatch::Board.new("coord", { "COORD_DIR" => dir, "COORD_ROLE" => "architect" })

      refute board.settled?(work(messages: %w[1.md]), 120)
      File.utime(Time.now - 200, Time.now - 200, File.join(inbox, "1.md"))
      assert board.settled?(work(messages: %w[1.md]), 120)
      assert board.settled?(work(unclaimed: %w[a]), 120)
    end
  end
end

class BoardFyiTest < Minitest::Test
  # An FYI message (coord msg --fyi) waits for the next turn. It pokes no one.
  def test_fyi_messages_are_no_work
    Dir.mktmpdir("board-watch-fyi") do |dir|
      inbox = File.join(dir, "inbox", "architect")
      FileUtils.mkdir_p(inbox)
      %w[1.fyi.md 2.md].each { |name| File.write(File.join(inbox, name), "x") }
      board = BoardWatch::Board.new("coord", { "COORD_DIR" => dir, "COORD_ROLE" => "architect" })

      assert_equal %w[2.md], board.send(:messages)
    end
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

  def watcher(board_work, running: false, checks: 3, message_age: 0)
    parts = BoardWatch::Parts.new(board: FakeBoard.new(board_work, message_age), session: FakeSession.new(running),
                                  owner: FakeOwner.new(checks), backoff: @backoff, batch: 120)
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

  # Each done task sends one message. One turn must read the whole group.
  def test_a_new_message_waits_for_the_rest_of_its_group
    assert_nil watcher(work(messages: %w[m1]), message_age: 30).wait_for_work
  end

  def test_an_old_message_pokes
    assert_equal %w[m1], watcher(work(messages: %w[m1]), message_age: 120).wait_for_work.messages
  end
end

class MainTest < Minitest::Test
  TASK_ID = "01234567-89ab-cdef-0123-456789abcdef"

  def test_does_nothing_without_a_role
    assert_equal 0, BoardWatch::Main.new({}, {}).run
  end

  def test_does_nothing_under_the_dispatcher
    env = { "COORD_ROLE" => "tester", "COORD_DISPATCHED" => "1" }

    assert_equal 0, BoardWatch::Main.new(env, {}).run
  end

  # A fake coord prints one task ID, so the watcher finds work at once.
  def with_fake_coord
    Dir.mktmpdir("board-watch-main") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".maf", "bin"))
      File.write(File.join(dir, ".maf", "bin", "coord"), "puts #{TASK_ID.inspect}\n")
      FileUtils.chmod("+x", File.join(dir, ".maf", "bin", "coord"))
      env = { "COORD_ROLE" => "tester", "COORD_DIR" => File.join(dir, ".maf/coordination"), "BOARD_WATCH_INTERVAL" => "0" }
      Dir.chdir(dir) { yield *registered(env, dir) }
    end
  end

  def registered(env, dir)
    env.merge!("COORD_WORKER" => "tester-1", "TASKRC" => File.join(env.fetch("COORD_DIR"), "taskrc"))
    FileUtils.mkdir_p(env.fetch("COORD_DIR"))
    File.write(env.fetch("TASKRC"), "")
    MafSession.register(dir, "claude", env)
    session_input(env, dir)
  end

  def session_input(env, dir)
    input = { "cwd" => dir, "session_id" => "test-session", "hook_event_name" => "SessionStart" }
    assert MafSession::Guard.new(env, input).authorized?
    [env, input.merge("hook_event_name" => "Stop")]
  end

  def test_pokes_the_role_from_coord_role
    with_fake_coord do |env, input|
      assert_output(nil, /role tester/) { assert_equal 2, BoardWatch::Main.new(env, input).run }
    end
  end

  def test_once_prints_the_poke_to_stdout
    with_fake_coord do |env, input|
      assert_output(/role tester/, "") { assert_equal 2, BoardWatch::Main.new(env, input).run_once }
    end
  end

  def test_once_does_not_repeat_an_unchanged_poke
    with_fake_coord do |env, input|
      env = env.merge("BOARD_WATCH_INTERVAL" => "60")
      assert_output(/role tester/) { BoardWatch::Main.new(env, input).run_once }

      assert_equal 0, BoardWatch::Main.new(env, input).run_once
    end
  end

  def test_once_does_nothing_under_the_dispatcher
    env = { "COORD_ROLE" => "tester", "COORD_DISPATCHED" => "1" }

    assert_equal 0, BoardWatch::Main.new(env, {}).run_once
  end
end
