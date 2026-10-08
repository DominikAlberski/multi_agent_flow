#!/usr/bin/env ruby
# frozen_string_literal: true

# test/dispatcher_test.rb - tests for assets/dispatcher.
#
# Run: ruby test/dispatcher_test.rb
#
# Tests the dispatcher without a real agent: fake harness commands are small
# shell scripts. The Poller is tested against a real `coord` board
# (disposable, project-local) if Taskwarrior is installed; otherwise it skips.
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "json"

load File.expand_path("../assets/coord", __dir__)
load File.expand_path("../assets/dispatcher", __dir__)

module DispatcherTestHelpers
  def config(**overrides)
    defaults = { role: "backend-developer", harness: "hermes", interval: 60, max_turns: 50, timeout: 300,
                 cache_window: 3300, max_session_runs: 5, max_context: 150_000, coord_dir: @dir, worker: "backend-developer-bot",
                 poll_tasks: true }
    Dispatcher::Config.new(**defaults, **overrides)
  end

  def write_message(role, name, from, text)
    dir = File.join(@dir, "inbox", role)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "# to: #{role}\n# from: #{from}\n# at: now\n\n#{text}\n")
  end

  def inbox(*parts) = Dir.glob(File.join(@dir, "inbox", "backend-developer", *parts, "*.md"))
end

class SessionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("dispatcher-session-test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def session = Dispatcher::Session.new(@dir, "tester")

  def test_returns_nil_when_no_session_file
    assert_nil session.id
  end

  def test_saves_and_reads_session_id
    session.save("20260101_abc")
    assert_equal "20260101_abc", session.id
  end

  def test_clear_removes_session_file
    session.save("x")
    session.clear
    assert_nil session.id
  end

  def test_idle_seconds_is_infinite_without_a_session
    assert_equal Float::INFINITY, session.idle_seconds
  end

  def test_idle_seconds_follows_the_last_save
    session.save("x")
    File.utime(Time.now - 7200, Time.now - 7200, session.path)
    assert_in_delta 7200, session.idle_seconds, 5
  end

  def test_counts_the_runs_of_one_session
    3.times { session.save("x") }
    assert_equal 3, session.runs
  end

  def test_a_new_session_id_restarts_the_count
    2.times { session.save("x") }
    session.save("y")
    assert_equal ["y", 1], [session.id, session.runs]
  end

  def test_ignores_empty_session_file
    FileUtils.mkdir_p(File.join(@dir, "sessions"))
    File.write(session.path, "  \n")
    assert_nil session.id
  end
end

class MailboxTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = Dir.mktmpdir("dispatcher-mailbox-test")
    @mailbox = Dispatcher::Mailbox.new(@dir, "backend-developer")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # The body keeps markdown headings; only the header block is metadata.
  def test_take_moves_messages_to_processing_and_parses_them
    write_message("backend-developer", "1.md", "architect", "# Plan\nDo it.")
    messages = @mailbox.take
    assert_equal ["architect"], messages.map(&:from)
    assert_equal "# Plan\nDo it.", messages.first.text
    assert_empty inbox
    assert_equal 1, inbox("processing").size
  end

  # Regression: peeked messages stayed unread, so a failed or skipped
  # `coord inbox` re-dispatched them every cycle forever.
  def test_taken_messages_are_not_taken_again
    write_message("backend-developer", "1.md", "architect", "hi")
    @mailbox.take
    assert_empty @mailbox.take
  end

  # Older coord versions wrote mail for a worker to inbox/<worker>/.
  def test_take_reads_the_old_worker_inbox_folders
    write_message("backend-developer-3", "1.md", "architect", "lost mail")
    write_message("backend-developer-x", "2.md", "architect", "other")
    assert_equal ["lost mail"], @mailbox.take.map(&:text)
  end

  def test_take_reads_the_worker_of_a_message
    path = File.join(@dir, "inbox", "backend-developer", "1.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# to: backend-developer\n# for: backend-developer-3\n# from: architect\n\nmerge\n")
    message = @mailbox.take.first
    assert_equal "backend-developer-3", message.worker
    assert_includes Dispatcher::Prompt.messages([message], "backend-developer"), "from architect for worker backend-developer-3"
  end

  def test_ack_moves_to_read
    write_message("backend-developer", "1.md", "architect", "hi")
    @mailbox.ack(@mailbox.take)
    assert_equal 1, inbox("read").size
  end

  def test_release_returns_to_inbox_then_fails_after_max_attempts
    write_message("backend-developer", "1.md", "architect", "hi")
    (Dispatcher::MAX_ATTEMPTS - 1).times { @mailbox.release(@mailbox.take) }
    assert_equal 1, inbox.size
    @mailbox.release(@mailbox.take)
    assert_empty inbox
    assert_equal 1, inbox("failed").size
  end

  # Regression: the attempt count lived in memory, so a message that always
  # fails bounced between inbox and processing forever across restarts.
  def test_attempt_count_survives_a_restart
    write_message("backend-developer", "1.md", "architect", "hi")
    Dispatcher::MAX_ATTEMPTS.times do
      mailbox = Dispatcher::Mailbox.new(@dir, "backend-developer")
      mailbox.release(mailbox.take)
    end
    assert_empty inbox
    assert_equal ["1.retry3.md"], inbox("failed").map { |path| File.basename(path) }
  end

  def test_recover_returns_orphaned_processing_messages
    write_message("backend-developer", "1.md", "architect", "hi")
    @mailbox.take
    Dispatcher::Mailbox.new(@dir, "backend-developer").recover
    assert_equal 1, inbox.size
  end
end

class TaskWatchTest < Minitest::Test
  def setup
    @watch = Dispatcher::TaskWatch.new(60)
    @now = Time.at(1_000_000)
  end

  def test_no_tasks_is_never_due
    refute @watch.due?([], @now)
  end

  def test_new_task_set_is_due_at_once
    assert @watch.due?(["a"], @now)
  end

  # Regression: an unclaimable task spawned an agent every interval forever.
  def test_same_task_set_backs_off_and_doubles
    @watch.dispatched(["a"], @now)
    refute @watch.due?(["a"], @now + 60)
    assert @watch.due?(["a"], @now + 120)
    @watch.dispatched(["a"], @now + 120)
    refute @watch.due?(["a"], @now + 120 + 239)
    assert @watch.due?(["a"], @now + 120 + 240)
  end

  def test_changed_task_set_is_due_at_once
    @watch.dispatched(["a"], @now)
    assert @watch.due?(%w[a b], @now + 1)
  end

  def test_backoff_is_capped
    10.times { |i| @watch.dispatched(["a"], @now + i) }
    assert @watch.due?(["a"], @now + 9 + Dispatcher::MAX_BACKOFF)
  end
end

class SpawnTest < Minitest::Test
  def test_captures_output_and_status
    result = Dispatcher::Spawn.run(["sh", "-c", "echo out; echo err >&2"], env: {}, timeout: 5)
    assert result.success
    assert_includes result.output, "out"
    assert_includes result.output, "err"
  end

  def test_passes_env
    result = Dispatcher::Spawn.run(["sh", "-c", "echo $COORD_WORKER"], env: { "COORD_WORKER" => "w-1" }, timeout: 5)
    assert_equal "w-1", result.output.strip
  end

  # Regression: --timeout only reached hermes as --run-budget; a hung agent
  # blocked the dispatcher forever. The whole process group must die.
  def test_kills_the_process_group_on_timeout
    started = Time.now
    result = Dispatcher::Spawn.run(["sh", "-c", "sleep 30 & sleep 30"], env: {}, timeout: 1)
    assert result.timed_out
    refute result.success
    assert_operator Time.now - started, :<, 10
  end

  # An agent CLI that reads stdin (codex does) must not hang on the terminal.
  def test_stdin_is_closed
    result = Dispatcher::Spawn.run(["cat"], env: {}, timeout: 5)
    assert result.success
    refute result.timed_out
  end

  def limits(**values) = Dispatcher::Limits.new(values.fetch(:idle, 0), values.fetch(:grace, 1),
                                                 values[:complete], values[:abort])

  # The agent prints the signal but a child keeps it alive: the run succeeds.
  def test_completion_signal_succeeds_and_stops_a_hanging_agent
    started = Time.now
    result = Dispatcher::Spawn.run(["sh", "-c", "echo work; echo DONE-1; sleep 30"], env: {}, timeout: 20,
                                                                                   limits: limits(complete: "DONE-1"))
    assert result.success
    assert_equal :complete, result.reason
    assert_operator Time.now - started, :<, 10
  end

  def test_completion_signal_wins_over_a_failing_exit_status
    result = Dispatcher::Spawn.run(["sh", "-c", "echo DONE-1; exit 3"], env: {}, timeout: 5,
                                                                       limits: limits(complete: "DONE-1"))
    assert result.success
  end

  def test_abort_signal_fails_even_with_exit_zero
    result = Dispatcher::Spawn.run(["sh", "-c", "echo GIVE-UP; exit 0"], env: {}, timeout: 5,
                                                                        limits: limits(abort: "GIVE-UP"))
    refute result.success
    assert_equal :abort, result.reason
  end

  def test_idle_timeout_fails_a_silent_agent
    started = Time.now
    result = Dispatcher::Spawn.run(["sh", "-c", "echo start; sleep 30"], env: {}, timeout: 20, limits: limits(idle: 1))
    refute result.success
    assert result.timed_out
    assert_equal :idle, result.reason
    assert_operator Time.now - started, :<, 10
  end

  def test_output_resets_the_idle_timer
    script = "for i in 1 2 3 4; do echo tick; sleep 0.5; done"
    result = Dispatcher::Spawn.run(["sh", "-c", script], env: {}, timeout: 20, limits: limits(idle: 1))
    assert result.success
    assert_equal :exit, result.reason
  end

  # A grandchild holds stdout after the agent exits: the exit status decides
  # after the grace window, and the run does not hang.
  def test_a_child_that_holds_stdout_does_not_block_the_run
    started = Time.now
    result = Dispatcher::Spawn.run(["sh", "-c", "(sleep 30 &); echo out"], env: {}, timeout: 20, limits: limits)
    assert result.success
    assert_includes result.output, "out"
    assert_operator Time.now - started, :<, 10
  end

  def test_missing_binary_is_a_failure
    result = Dispatcher::Spawn.run(["no-such-agent-binary"], env: {}, timeout: 5)
    refute result.success
  end
end

class HermesHarnessTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = "/tmp"
  end

  def hermes = Dispatcher::Harness::Hermes

  def test_build_command_with_skill_model_and_resume
    cmd = hermes.build_command(config(skill: "p-backend-developer", model: "m"), "go", "sess-1")
    assert_equal %w[hermes chat --oneshot --yolo --format stream-json -Q], cmd.first(7)
    assert_includes cmd.each_cons(2).to_a, ["--skills", "p-backend-developer"]
    assert_includes cmd.each_cons(2).to_a, ["--model", "m"]
    assert_includes cmd.each_cons(2).to_a, ["--resume", "sess-1"]
    assert_equal ["-q", "go"], cmd.last(2)
  end

  def test_build_command_without_skill_or_session
    cmd = hermes.build_command(config, "go", nil)
    refute_includes cmd, "--skills"
    refute_includes cmd, "--resume"
  end

  # Shapes taken from hermes_cli/stream_json.py and a real `--resume bogus` run.
  def test_parses_session_id_and_text_from_the_result_event
    output = <<~OUT
      {"type": "system", "subtype": "init", "session_id": ""}
      {"type": "text", "text": "partial"}
      {"type": "result", "session_id": "s-42", "exit_code": 0, "text": "all done"}
    OUT
    assert_equal "s-42", hermes.session_id(output)
    assert_equal "all done", hermes.result_text(output)
  end

  def test_parse_tolerates_garbage
    assert_nil hermes.session_id("not json\n{broken")
    assert_nil hermes.result_text("")
  end

  def test_detects_a_stale_session
    assert hermes.stale_session?("Session not found: bogus\nUse a session ID from a previous CLI run")
    refute hermes.stale_session?("rate limited")
  end

  def test_unknown_harness_aborts
    assert_raises(SystemExit) { capture_io { Dispatcher::Harness.for(config(harness: "nope")) } }
  end

  def test_command_selects_the_generic_adapter
    assert_equal Dispatcher::Harness::Generic, Dispatcher::Harness.for(config(harness: "nope", command: "x"))
  end
end

class GenericHarnessTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = "/tmp"
  end

  def build(template, **overrides)
    Dispatcher::Harness::Generic.build_command(config(command: template, **overrides), "fix it; rm -rf /", nil)
  end

  def test_substitutes_and_escapes_placeholders
    cmd = build("agent %{role} %{skill} %{prompt}", skill: "p-backend-developer")
    assert_equal "sh", cmd.first
    assert_equal "agent backend-developer p-backend-developer fix\\ it\\;\\ rm\\ -rf\\ /", cmd.last
  end

  # Regression: gsub read the \' of an escaped apostrophe as the text after
  # the match, so a prompt with "user's" broke the shell command.
  def test_an_apostrophe_in_the_prompt_survives_the_template
    cmd = Dispatcher::Harness::Generic.build_command(config(command: "printf %s %{prompt}"), "the user's fix", nil)
    assert_equal "the user's fix", IO.popen(cmd, &:read)
  end

  def test_has_no_session_support
    refute Dispatcher::Harness::Generic.stale_session?("Session not found")
    assert_nil Dispatcher::Harness::Generic.session_id("{}")
  end
end

class RunnerTest < Minitest::Test
  include DispatcherTestHelpers

  # FakeHarness runs a shell snippet and reports "Session not found" as stale.
  module FakeHarness
    def self.build_command(config, prompt, session_id) = ["sh", "-c", config.command, "sh", session_id.to_s, prompt]
    def self.stale_session?(output) = output.include?("Session not found")
    def self.session_id(output) = output[/session=(\S+)/, 1]
    def self.result_text(output) = output[/^reply: (.*)/m, 1] || "ok #{DONE}"
    def self.usage(output) = output[/tokens=(\d+)/, 1]&.then { |n| { "input_tokens" => n.to_i, "output_tokens" => 1 } }
    def self.model(output) = output[/model=(\S+)/, 1]
    def self.context(output) = output[/context=(\d+)/, 1]&.to_i
  end

  DONE = '<report>{"status":"done","tests":"pass"}</report>'

  def setup
    @dir = Dir.mktmpdir("dispatcher-runner-test")
    @calls = File.join(@dir, "calls")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def runner(script) = Dispatcher::Runner.new(config(command: script, timeout: 5), FakeHarness, {})
  def session = Dispatcher::Session.new(@dir, "backend-developer-bot")

  def test_success_saves_the_session_id
    capture_io { assert_equal :done, runner("echo session=new-1").dispatch("go") }
    assert_equal "new-1", session.id
  end

  def test_stale_session_retries_once_with_a_fresh_session
    session.save("old")
    script = %(echo "$1" >> #{@calls}; [ "$1" = old ] && { echo "Session not found: old"; exit 1; }; echo session=new-2)
    capture_io { assert_equal :done, runner(script).dispatch("go") }
    assert_equal ["old", ""], File.readlines(@calls, chomp: true)
    assert_equal "new-2", session.id
  end

  def runner_with_window(script, window)
    Dispatcher::Runner.new(config(command: script, timeout: 5, cache_window: window), FakeHarness, {})
  end

  def record_call = %(echo "$1" >> #{@calls}; printf '%s' "$2" > #{@calls}.prompt; echo session=s-1)

  def test_warm_session_is_resumed
    session.save("s-1")
    capture_io { runner(record_call).dispatch("go") }
    assert_equal ["s-1"], File.readlines(@calls, chomp: true)
  end

  # Past the cache window a resume resends the whole context at full price,
  # so the runner starts fresh and passes the handoff note instead.
  def test_cold_session_starts_fresh_with_the_handoff_note
    session.save("s-1")
    File.write(session.handoff_path, "Auth module half done.")
    File.utime(Time.now - 7200, Time.now - 7200, session.path)
    capture_io { runner(record_call).dispatch("go") }
    assert_equal [""], File.readlines(@calls, chomp: true)
    assert_includes File.read("#{@calls}.prompt"), "Handoff note from your previous session:\nAuth module half done."
  end

  def test_resumed_prompt_has_no_handoff_note_but_asks_for_a_new_one
    session.save("s-1")
    File.write(session.handoff_path, "old note")
    capture_io { runner(record_call).dispatch("go") }
    prompt = File.read("#{@calls}.prompt")
    refute_includes prompt, "old note"
    assert_includes prompt, "<handoff>"
  end

  def test_a_handoff_block_in_the_final_reply_becomes_the_note
    FileUtils.mkdir_p(File.dirname(session.handoff_path))
    File.write(session.handoff_path, "old note")
    capture_io { runner(reply("done <handoff>Auth half done.</handoff> #{DONE}")).dispatch("go") }
    assert_equal "Auth half done.", session.handoff
  end

  # Some models skip the handoff instruction; the final reply fills in.
  def test_final_reply_becomes_the_note_when_the_agent_wrote_none
    capture_io { runner(record_call).dispatch("go") }
    assert_equal "ok", session.handoff
  end

  def test_a_note_the_agent_wrote_is_kept
    FileUtils.mkdir_p(File.dirname(session.handoff_path))
    capture_io { runner("echo agent-note > #{session.handoff_path}").dispatch("go") }
    assert_equal "agent-note", session.handoff
  end

  # Each resume sends the whole old context again. A full session starts fresh.
  def test_a_session_at_the_run_limit_starts_fresh
    5.times { session.save("s-1") }
    _out, err = capture_io { runner(record_call).dispatch("go") }
    assert_equal [""], File.readlines(@calls, chomp: true)
    assert_includes err, "has 5 runs, the --max-session-runs limit"
  end

  # Each task in a resumed session adds to the context. A large session starts fresh.
  def test_a_session_at_the_context_limit_starts_fresh
    session.save("s-1", 150_000)
    _out, err = capture_io { runner(record_call).dispatch("go") }
    assert_equal [""], File.readlines(@calls, chomp: true)
    assert_includes err, "has 150000 context tokens, the --max-context limit"
  end

  def history = File.readlines(File.join(@dir, "usage", "backend-developer-bot.runs.jsonl")).map { JSON.parse(_1) }

  # The dashboard turns the run history into hints.
  def test_each_run_adds_a_history_line
    session.save("s-1")
    capture_io { runner(%(echo session=s-1 tokens=900 context=4200)).dispatch("go") }
    line = history.last
    assert_equal [2, 4200, 900], line.values_at("session_run", "context", "input_tokens")
    assert_equal({ "max_context" => 150_000, "max_session_runs" => 5, "cache_window" => 3300 }, line["limits"])
  end

  def test_a_fresh_session_is_session_run_one
    capture_io { runner(%(echo session=s-1 tokens=900)).dispatch("go") }
    assert_equal 1, history.last["session_run"]
  end

  def test_the_context_of_the_last_call_is_saved
    capture_io { runner("echo session=s-1 context=4200").dispatch("go") }
    assert_equal 4200, session.context_tokens
  end

  def test_a_zero_context_limit_never_caps_the_session
    session.save("s-1", 900_000)
    runner = Dispatcher::Runner.new(config(command: record_call, timeout: 5, max_context: 0), FakeHarness, {})
    capture_io { runner.dispatch("go") }
    assert_equal ["s-1"], File.readlines(@calls, chomp: true)
  end

  def test_a_zero_run_limit_never_caps_the_session
    9.times { session.save("s-1") }
    runner = Dispatcher::Runner.new(config(command: record_call, timeout: 5, max_session_runs: 0), FakeHarness, {})
    capture_io { runner.dispatch("go") }
    assert_equal ["s-1"], File.readlines(@calls, chomp: true)
  end

  # A run that changed nothing must not replace the note with "no tasks".
  def test_the_final_reply_never_replaces_an_existing_note
    FileUtils.mkdir_p(File.dirname(session.handoff_path))
    File.write(session.handoff_path, "real state")
    capture_io { runner(reply("No tasks available. #{DONE}")).dispatch("go") }
    assert_equal "real state", session.handoff
  end

  def test_zero_window_never_resumes
    session.save("s-1")
    capture_io { runner_with_window(record_call, 0).dispatch("go") }
    assert_equal [""], File.readlines(@calls, chomp: true)
  end

  def test_stale_retry_gets_the_handoff_note
    session.save("old")
    File.write(session.handoff_path, "carry this")
    script = %(printf '%s' "$2" > #{@calls}.prompt; [ "$1" = old ] && { echo "Session not found"; exit 1; }; true)
    capture_io { runner(script).dispatch("go") }
    assert_includes File.read("#{@calls}.prompt"), "carry this"
  end

  def reply(text) = %(echo "$1" >> #{@calls}; echo session=s-1; printf 'reply: %s' '#{text}')
  def calls = File.readlines(@calls, chomp: true)

  def test_report_done_is_a_success
    capture_io { assert_equal :done, runner(reply("ok #{DONE}")).dispatch("go") }
    assert_equal [""], calls
  end

  # An agent that gives up but exits 0 must not count as done. It waits.
  def test_report_blocked_waits_and_keeps_the_session
    blocked = '<report>{"status":"blocked","next":"ask the architect"}</report>'
    out, err = capture_io { assert_equal :waiting, runner(reply("stuck #{blocked}")).dispatch("go") }
    assert_equal "s-1", session.id
    assert_includes out + err, "status blocked"
  end

  def test_report_needs_review_waits
    capture_io { assert_equal :waiting, runner(reply('<report>{"status":"needs_review"}</report>')).dispatch("go") }
    assert_equal [false, "waiting"], worker_status["last_run"].values_at("success", "outcome")
  end

  def test_missing_block_resumes_the_session_once_then_counts_the_exit_status
    capture_io { assert_equal :done, runner(reply("no block")).dispatch("go") }
    assert_equal ["", "s-1"], calls
  end

  # Regression: the report retry counted as a second run toward --max-session-runs.
  def test_a_report_retry_does_not_count_as_a_session_run
    capture_io { runner(reply("no block")).dispatch("go") }
    assert_equal 2, calls.size
    assert_equal 1, session.runs
  end

  def test_invalid_block_resumes_once_then_fails
    capture_io { assert_equal :failed, runner(reply('<report>{"status":"maybe"}</report>')).dispatch("go") }
    assert_equal ["", "s-1"], calls
  end

  def test_retry_prompt_names_the_validation_error
    script = %(echo session=s-1; printf '%s' "$2" >> #{@calls}.prompt; printf 'reply: <report>{"status":"x"}</report>')
    capture_io { runner(script).dispatch("go") }
    assert_includes File.read("#{@calls}.prompt"), "Your report block is invalid: status must be one of"
  end

  # A custom command has no session, so the runner cannot resume it.
  def test_missing_block_without_a_session_counts_the_exit_status
    capture_io { assert_equal :done, runner(%(echo x >> #{@calls}; printf 'reply: plain')).dispatch("go") }
    assert_equal ["x"], calls
  end

  def test_abort_signal_fails_the_run_and_logs_it
    runner = Dispatcher::Runner.new(config(command: "echo GIVE-UP", timeout: 5, abort_signal: "GIVE-UP"), FakeHarness, {})
    out, err = capture_io { assert_equal :failed, runner.dispatch("go") }
    assert_includes out + err, "sent the abort signal"
  end

  def with_verify(command, &block)
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(verify: command))
    Dir.chdir(@dir, &block)
  end

  def test_failing_verify_command_makes_a_done_run_no_success
    with_verify("echo broken; exit 1") do
      out, err = capture_io { assert_equal :failed, runner(reply("ok #{DONE}")).dispatch("go") }
      assert_includes out + err, "verify command failed (echo broken; exit 1): broken"
    end
  end

  def test_passing_verify_command_keeps_the_success
    with_verify("true") { capture_io { assert_equal :done, runner(reply("ok #{DONE}")).dispatch("go") } }
  end

  def test_a_lead_role_gets_no_verify_check
    with_verify("exit 1") do
      lead = Dispatcher::Runner.new(config(role: "architect", command: reply("ok #{DONE}"), timeout: 5), FakeHarness, {})
      capture_io { assert_equal :done, lead.dispatch("go") }
    end
  end

  def usage_totals = JSON.parse(File.read(File.join(@dir, "usage", "backend-developer-bot.json")))

  def test_token_usage_adds_up_per_worker
    2.times { capture_io { runner("echo tokens=10").dispatch("go") } }
    assert_equal({ "input_tokens" => 20, "output_tokens" => 2, "runs" => 2 }, usage_totals)
  end

  def worker_status = JSON.parse(File.read(File.join(@dir, "status", "backend-developer-bot.json")))

  # The dashboard shows which model a worker runs and how its last run ended.
  def test_a_run_writes_the_worker_status
    capture_io { runner(%(echo session=s-1; echo model=claude-opus-5-5; printf 'reply: ok #{DONE}')).dispatch("go") }
    status = worker_status
    assert_equal ["dispatch", false, "claude-opus-5-5"], status.values_at("mode", "running", "model")
    assert_equal true, status.dig("last_run", "success")
    assert_includes status.dig("last_run", "detail"), "agent finished"
  end

  def test_a_failed_run_shows_the_failure_in_the_status
    capture_io { runner("echo boom; exit 1").dispatch("go") }
    assert_equal false, worker_status.dig("last_run", "success")
    assert_includes worker_status.dig("last_run", "detail"), "boom"
  end

  def test_a_run_without_usage_writes_nothing
    capture_io { assert_equal :done, runner("echo plain").dispatch("go") }
    refute File.exist?(File.join(@dir, "usage"))
  end

  def test_a_broken_usage_file_never_fails_the_run
    FileUtils.mkdir_p(File.join(@dir, "usage"))
    File.write(File.join(@dir, "usage", "backend-developer-bot.json"), "{broken")
    capture_io { assert_equal :done, runner("echo tokens=10").dispatch("go") }
  end

  def test_handoff_note_drops_the_report_block
    capture_io { runner(reply("state #{DONE}")).dispatch("go") }
    assert_equal "state", session.handoff
  end

  # Regression: any non-zero exit cleared the session and re-ran the agent,
  # losing context and doubling the cost.
  def test_other_failures_keep_the_session_and_do_not_retry
    session.save("old")
    capture_io { assert_equal :failed, runner(%(echo "$1" >> #{@calls}; echo "boom"; exit 1)).dispatch("go") }
    assert_equal ["old"], File.readlines(@calls, chomp: true)
    assert_equal "old", session.id
  end
end

class MainTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = Dir.mktmpdir("dispatcher-main-test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_cycle(command)
    main = Dispatcher::Main.new(config(command: command, poll_tasks: false, timeout: 5))
    capture_io { main.cycle }
  end

  # All unread messages go to one agent run, not one run per message.
  def test_bundles_messages_into_one_run_and_acks_them
    write_message("backend-developer", "1.md", "architect", "first")
    write_message("backend-developer", "2.md", "reviewer", "second")
    calls = File.join(@dir, "calls")
    run_cycle("echo %{prompt} >> #{calls}")
    prompt = File.read(calls)
    assert_equal 1, prompt.scan("The dispatcher took these messages").size
    assert_equal 2, prompt.scan("--- message from").size
    assert_equal 2, inbox("read").size
  end

  # Regression: a lead that waited for reviews got its messages back three
  # times, and then the messages moved to failed/.
  def test_a_waiting_run_acks_its_messages
    write_message("backend-developer", "1.md", "architect", "first")
    run_cycle(%(printf '<report>{"status":"needs_review","next":"wait"}</report>'))
    assert_equal 1, inbox("read").size
    assert_empty inbox
  end

  def test_a_failed_run_returns_its_messages
    write_message("backend-developer", "1.md", "architect", "first")
    run_cycle("exit 1")
    assert_equal 1, inbox.size
    assert_empty inbox("read")
  end

  # FakePoller claims every task except the ones in taken.
  FakePoller = Struct.new(:ids, :claimed, :taken) do
    def unclaimed_task_ids = ids
    def claimed_task_ids = claimed || []
    def claim_first(list) = list.find { |id| !(taken || []).include?(id) }
    def show(id) = "uuid: #{id}\ndescription: fix login"
    def coord_dir = "/nonexistent/coordination"
  end

  # A message run already tells the agent to work through `coord next`, so a
  # cycle with both a message and a task starts one run, and the next cycle
  # backs off on the unchanged task set.
  def test_one_run_per_cycle_with_messages_and_tasks
    write_message("backend-developer", "1.md", "architect", "first")
    calls = File.join(@dir, "calls")
    main = Dispatcher::Main.new(config(command: "echo run >> #{calls}", timeout: 5))
    main.instance_variable_set(:@poller, FakePoller.new(["t1"]))
    capture_io { 2.times { main.cycle } }
    assert_equal 1, File.readlines(calls).size
  end

  # Regression: a dead run kept its claim for an hour, and no run resumed the task.
  def test_a_claimed_task_gets_a_resume_run_before_new_tasks
    calls = File.join(@dir, "calls")
    main = Dispatcher::Main.new(config(command: "echo %{prompt} >> #{calls}", timeout: 5))
    main.instance_variable_set(:@poller, FakePoller.new(["t2"], ["t1"]))
    capture_io { main.cycle }

    prompt = File.read(calls)
    assert_includes prompt, "You hold claimed tasks that a previous run did not finish: t1."
    refute_includes prompt, "Unclaimed tasks exist"
  end

  def task_cycle(poller)
    calls = File.join(@dir, "calls")
    main = Dispatcher::Main.new(config(command: "echo %{prompt} >> #{calls}", timeout: 5))
    main.instance_variable_set(:@poller, poller)
    _out, err = capture_io { main.cycle }
    [File.exist?(calls) ? File.read(calls) : nil, err]
  end

  # Regression: a third of the runs of a reviewer pool found no work, because
  # another worker took the task first. The dispatcher claims before the run.
  def test_a_task_run_starts_only_after_a_claim
    prompt, = task_cycle(FakePoller.new(%w[t1 t2], [], ["t1"]))
    assert_includes prompt, "The dispatcher claimed task t2 for you."
    assert_includes prompt, "Do not claim another task."
  end

  def test_no_run_when_another_worker_took_every_task
    prompt, = task_cycle(FakePoller.new(["t1"], [], ["t1"]))
    assert_nil prompt
  end

  def test_a_task_run_gets_the_task_spec_and_the_git_log
    prompt, = task_cycle(FakePoller.new(["t1"]))
    assert_includes prompt, "$ coord show t1\nuuid: t1\ndescription: fix login"
    assert_includes prompt, "$ git log --oneline -10\n"
  end

  # Some models grep instead of querying the graph. The prompt brings the graph query along.
  def test_a_task_run_gets_a_graph_query_on_the_task_description
    coord = File.join(@dir, ".maf", "coordination")
    FileUtils.mkdir_p([coord, File.join(@dir, "graphify-out"), File.join(@dir, "bin")])
    File.write(File.join(@dir, "graphify-out", "graph.json"), "{}")
    File.write(File.join(@dir, "bin", "graphify"), "#!/bin/sh\necho \"NODE app.rb args: $2 $4\"\n")
    FileUtils.chmod(0o755, File.join(@dir, "bin", "graphify"))
    poller = FakePoller.new(["t1"]).tap { |p| p.define_singleton_method(:coord_dir) { coord } }
    prompt, = with_path(File.join(@dir, "bin")) { task_cycle(poller) }
    assert_includes prompt, "$ graphify query <task description> --budget 500\nNODE app.rb args: fix login 500"
  end

  def test_no_graph_query_without_a_graph
    prompt, = task_cycle(FakePoller.new(["t1"]))
    refute_includes prompt, "graphify query"
  end

  # The format of `graphify reflect`. "## By topic" repeats the lessons.
  LESSONS_MD = <<~MD
    # Lessons

    ## Lessons

    **Preferred sources** — corroborated by ≥2 useful results; start here.

    - `app.rb` (2× useful)

    **Known dead ends** — led nowhere; don't re-derive.

    - "cache prices" — `price.rb`

    **Corrections** — do these differently.

    - "fix login" → use the session store

    ## By topic

    ### Prices

    **Known dead ends** — led nowhere; don't re-derive.

    - "cache prices" — `price.rb`
  MD

  CORRECTION = "correction: \"fix login\" → use the session store\n"
  DEAD_END = "dead end: \"cache prices\" — `price.rb`\n"

  # A graphify-out folder with LESSONS_MD, one note for each lesson, and a graph
  # with an absolute and a relative source path.
  def lessons_dir
    out = File.join(@dir, "graphify-out")
    FileUtils.mkdir_p([File.join(out, "reflections"), File.join(out, "memory")])
    File.write(File.join(out, "reflections", "LESSONS.md"), LESSONS_MD)
    write_note(out, "cache prices", "price_rb")
    write_note(out, "fix login", "login_rb")
    nodes = [{ id: "price_rb", source_file: "app/price.rb" }, { id: "login_rb", source_file: "#{@dir}/app/login.rb" }]
    File.write(File.join(out, "graph.json"), JSON.generate(nodes: nodes))
    out
  end

  def write_note(out, question, node)
    File.write(File.join(out, "memory", "#{node}.md"),
               "---\nquestion: #{question.to_json}\nsource_nodes: [#{node.to_json}]\n---\n\n# Q: #{question}\n")
  end

  def test_lessons_list_the_dead_ends_and_corrections_newest_first
    assert_equal [CORRECTION, DEAD_END], Dispatcher::Lessons.for_task(lessons_dir, nil)
  end

  def test_lessons_keep_only_the_files_of_the_graph_query
    query = "NODE .login() [src=app/login.rb loc=L3 community=Login]\n"
    assert_equal [CORRECTION], Dispatcher::Lessons.for_task(lessons_dir, query)
  end

  def test_a_lesson_without_a_cited_node_stays
    out = lessons_dir
    FileUtils.rm(File.join(out, "memory", "login_rb.md"))
    query = "NODE Price [src=app/price.rb loc=L1 community=Prices]\n"
    assert_equal [CORRECTION, DEAD_END], Dispatcher::Lessons.for_task(out, query)
  end

  def test_no_lessons_section_without_lessons_for_the_task
    query = "NODE Cart [src=app/cart.rb]\n"
    run = Dispatcher::Prefetch.lessons(lessons_dir, -> { query }).values.first
    refute Dispatcher::Prefetch.section("lessons", run)
  end

  def test_no_lessons_without_dead_ends_or_corrections
    out = File.join(@dir, "graphify-out")
    FileUtils.mkdir_p(File.join(out, "reflections"))
    assert_empty Dispatcher::Lessons.for_task(out, nil)
    File.write(File.join(out, "reflections", "LESSONS.md"), "# Lessons\n\n## Lessons\n\n_No marked outcomes yet._\n")
    assert_empty Dispatcher::Lessons.for_task(out, nil)
  end

  def with_path(dir)
    old = ENV["PATH"]
    ENV["PATH"] = "#{dir}:#{old}"
    yield
  ensure
    ENV["PATH"] = old
  end

  def test_prefetch_text_is_bounded
    text = Dispatcher::Prefetch.section("x", -> { "x" * 5000 })
    assert_includes text, "[cut at #{Dispatcher::Prefetch::LIMIT} characters]"
    refute_includes text, "x" * (Dispatcher::Prefetch::LIMIT + 1)
  end

  def test_a_message_run_gets_only_the_git_log
    write_message("backend-developer", "1.md", "architect", "first")
    prompt, = task_cycle(FakePoller.new([]))
    assert_includes prompt, "$ git log --oneline -10\n"
    refute_includes prompt, "$ coord"
  end

  def test_a_failed_prefetch_is_logged_and_the_run_goes_on
    write_message("backend-developer", "1.md", "architect", "first")
    prompt, err = Dir.chdir(@dir) { task_cycle(FakePoller.new([])) }
    assert_includes err, "prefetch failed: git log --oneline -10"
    assert_includes prompt, "The dispatcher took these messages"
    assert_equal 1, inbox("read").size
  end

  def test_failed_run_returns_messages_to_the_inbox
    write_message("backend-developer", "1.md", "architect", "first")
    run_cycle("exit 1")
    assert_equal 1, inbox.size
  end

  def test_agent_gets_the_coord_environment
    write_message("backend-developer", "1.md", "architect", "first")
    out = File.join(@dir, "env")
    run_cycle(%(echo "$COORD_DIR $COORD_ROLE $COORD_WORKER $COORD_DISPATCHED" > #{out}))
    assert_equal "#{@dir} backend-developer backend-developer-bot 1", File.read(out).strip
  end
end

class OptionsTest < Minitest::Test
  def parse(*argv) = Dispatcher::Options.parse(argv, { "COORD_DIR" => "/tmp/c" })

  def test_defaults
    config = parse("reviewer", "--no-skill")
    assert_equal "reviewer", config.role
    assert_equal "reviewer-bot", config.worker
    assert_equal "/tmp/c", config.coord_dir
    assert config.poll_tasks
    assert_nil config.skill
  end

  def test_flags
    config = parse("reviewer", "--no-poll-tasks", "--interval", "5", "--skill", "s", "--once")
    refute config.poll_tasks
    assert_equal 5, config.interval
    assert_equal "s", config.skill
    assert config.once
  end

  def test_timeout_split_flags
    config = parse("reviewer", "--idle-timeout", "90", "--grace", "2", "--completion-signal", "OK!",
                   "--abort-signal", "NO!")
    assert_equal [90, 2, "OK!", "NO!"], Dispatcher::Limits.from(config).to_a
    assert_equal 1500, config.timeout
  end

  def test_idle_timeout_is_off_by_default
    assert_equal [0, Dispatcher::Spawn::GRACE, nil, nil], Dispatcher::Limits.from(parse("reviewer")).to_a
  end

  def test_rejects_a_negative_idle_timeout
    assert_raises(SystemExit) { capture_io { parse("reviewer", "--idle-timeout", "-1") } }
  end

  def test_rejects_a_zero_interval
    assert_raises(SystemExit) { capture_io { parse("reviewer", "--interval", "0") } }
  end

  def test_rejects_an_empty_role
    assert_raises(SystemExit) { capture_io { parse("") } }
  end

  def test_requires_a_role
    assert_raises(SystemExit) { capture_io { parse } }
  end
end

class PromptTest < Minitest::Test
  def test_messages_prompt_includes_every_message_and_the_one_shot_rules
    messages = [Dispatcher::Message.new("p", "architect", "do x"), Dispatcher::Message.new("p", "pm", "do y")]
    prompt = Dispatcher::Prompt.messages(messages, "backend-developer")
    assert_includes prompt, "--- message from architect ---\ndo x"
    assert_includes prompt, "--- message from pm ---\ndo y"
    assert_includes prompt, "Follow your role instructions"
    assert_includes prompt, "Do not use --wait"
  end

  def test_dispatch_prompt_asks_for_the_report_block
    session = Dispatcher::Session.new("/tmp/none", "w")
    assert_includes Dispatcher::Prompt.with_handoff("go", session, nil), Dispatcher::ReportBlock::REPORT_FORMAT
  end

  def test_signals_are_only_in_the_prompt_when_set
    config = Dispatcher::Config.new(completion_signal: "DONE-1")
    assert_includes Dispatcher::Prompt.signals(config), "print DONE-1"
    assert_equal "", Dispatcher::Prompt.signals(Dispatcher::Config.new)
  end

  def test_task_prompt_names_the_role_and_the_task
    prompt = Dispatcher::Prompt.task("tester", "t1")
    assert_includes prompt, "role tester"
    assert_includes prompt, "claimed task t1"
  end

  # The dispatcher claims each task. A message run must not take one.
  def test_messages_prompt_for_a_worker_forbids_a_claim
    prompt = Dispatcher::Prompt.messages([Dispatcher::Message.new("p", "architect", "x")], "tester")
    assert_includes prompt, "Do not claim a task"
  end

  # A lead role owns no task. The prompt must not tell it to claim one.
  def test_messages_prompt_for_a_lead_role_forbids_a_claim
    prompt = Dispatcher::Prompt.messages([Dispatcher::Message.new("p", "project-manager", "GOAL x")], "architect")

    assert_includes prompt, "Never claim a task"
    refute_includes prompt, "claim a task, do the work"
  end
end

class LeadOptionsTest < Minitest::Test
  def test_a_lead_role_does_not_poll_tasks
    refute Dispatcher::Options.parse(%w[architect --no-skill], { "COORD_DIR" => "/tmp/c" }).poll_tasks
  end
end

class EditGrantTest < Minitest::Test
  MANIFEST = { "agents" => [{ "harness" => "hermes", "role" => "reviewer", "can_edit" => false },
                            { "harness" => "hermes", "role" => "tester", "can_edit" => true }] }.freeze

  def setup
    @dir = File.realpath(Dir.mktmpdir("dispatcher-grant-test"))
    system("git", "init", "-q", @dir, exception: true)
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(MANIFEST))
  end

  def teardown = FileUtils.remove_entry(@dir)

  def command(role)
    config = Dispatcher::Config.new(role: role, max_turns: 5, timeout: 60)
    Dir.chdir(@dir) { Dispatcher::Harness::Hermes.build_command(config, "go", nil) }
  end

  def test_a_read_only_role_gets_the_limited_toolsets
    assert_includes command("reviewer").each_cons(2).to_a, ["-t", Dispatcher::EditGrant::READ_ONLY_TOOLSETS]
  end

  def test_an_editing_role_keeps_every_toolset
    refute_includes command("tester"), "-t"
  end
end

class PresenceWriteTest < Minitest::Test
  include DispatcherTestHelpers

  def setup = @dir = Dir.mktmpdir("dispatcher-presence-test")
  def teardown = FileUtils.remove_entry(@dir)

  def test_a_cycle_records_the_dispatcher_as_present
    Dispatcher::Main.new(config(command: "true", poll_tasks: false)).cycle
    record = JSON.parse(File.read(File.join(@dir, "presence", "backend-developer-bot.json")))

    assert_equal %w[backend-developer dispatch], record.values_at("role", "mode")
    assert_equal Process.pid, record["pid"]
  end

  def test_the_presence_record_holds_the_process_start_time
    record = Dispatcher::Presence.record(config)

    refute_empty record["started"]
  end

  def test_the_agent_environment_carries_the_dispatcher_directory
    assert_equal Dir.pwd, Dispatcher::Main.run_env(config)["PWD"]
  end
end

class SessionIdTest < Minitest::Test
  def harness(name) = Dispatcher::Harness::REGISTRY.fetch(name)

  # Captured from a real `opencode run --format json`: an escape-code prefix,
  # and a JSON event glued onto the end of a notify line.
  OPENCODE_LINE = "\e]777;notify;warp://cli-agent;{\"event\":\"prompt_submit\",\"session_id\":\"ses_other\"}" \
                  "{\"type\":\"error\",\"timestamp\":1790174271790,\"sessionID\":\"ses_abc\",\"error\":{}}\n"

  def test_opencode_id_comes_from_an_event_even_when_glued
    assert_equal "ses_abc", harness("opencode").session_id(OPENCODE_LINE)
  end

  def test_codex_id_comes_from_thread_started
    assert_equal "t-1", harness("codex").session_id(%({"type":"thread.started","thread_id":"t-1"}\n))
  end

  # Regression: the ID was the last "session_id" anywhere in the output, so
  # an agent that echoed a prompt or a note could supply a false one.
  def test_echoed_text_cannot_supply_a_session_id
    output = <<~OUT
      tool output: {"session_id": "fake"}
      {"type": "result", "session_id": "real", "text": "done"}
      stderr: "session_id": "fake2"
    OUT
    assert_equal "real", harness("hermes").session_id(output)
    assert_nil harness("codex").session_id(%(echo {"thread_id":"fake"}\n))
    assert_nil harness("opencode").session_id(%(note: "sessionID":"fake"\n))
  end

  def test_empty_ids_are_ignored
    assert_nil harness("hermes").session_id(%({"type": "result", "session_id": ""}\n))
  end
end

class AdapterTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = "/tmp"
  end

  def harness(name) = Dispatcher::Harness::REGISTRY.fetch(name)
  def pairs(cmd) = cmd.each_cons(2).to_a

  # The flow keeps its MCP config in .maf/mcp/, next to the coordination folder.
  def test_a_dispatched_run_gets_the_mcp_config_of_the_flow
    Dir.mktmpdir do |root|
      mcp = File.join(root, "mcp")
      FileUtils.mkdir_p(mcp)
      %w[claude.json opencode.json].each { |name| File.write(File.join(mcp, name), "{}") }
      cfg = config(coord_dir: File.join(root, "coordination"))

      command = harness("claude").build_command(cfg, "go", nil)
      assert_includes pairs(command), ["--mcp-config", File.join(mcp, "claude.json")]
      assert_equal ["--", "go"], command.last(2), "--mcp-config takes many values; -- keeps the prompt out"
      assert_equal File.join(mcp, "opencode.json"), Dispatcher::Main.run_env(cfg)["OPENCODE_CONFIG"]
    end
  end

  def test_claude_command
    fresh = harness("claude").build_command(config(model: "haiku"), "go", nil)
    assert_equal %w[claude -p --output-format json], fresh.first(4)
    assert_includes pairs(fresh), ["--agent", "backend-developer"]
    assert_includes pairs(fresh), ["--model", "haiku"]
    refute_includes fresh, "--resume"
    assert_includes pairs(harness("claude").build_command(config, "go", "s-1")), ["--resume", "s-1"]
  end

  def test_claude_output
    output = %({"type":"result","subtype":"success","result":"ok","session_id":"b847"}\n)
    assert_equal "b847", harness("claude").session_id(output)
    assert_equal "ok", harness("claude").result_text(output)
    assert harness("claude").stale_session?("No conversation found with session ID: 0000")
  end

  # Codex has no agent flag: a fresh session gets the role prompt file.
  def test_codex_command
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".codex/prompts")
        File.write(".codex/prompts/backend-developer.md", "ROLE")
        fresh = harness("codex").build_command(config, "go", nil)
        resumed = harness("codex").build_command(config, "go", "t-1")
        assert_equal %w[codex exec --json], fresh.first(3)
        assert_equal "ROLE\n\ngo", fresh.last
        assert_equal ["t-1", "go"], resumed.last(2)
        assert_equal %w[codex exec resume], resumed.first(3)
      end
    end
  end

  def test_codex_output
    output = <<~OUT
      {"type":"thread.started","thread_id":"t-1"}
      {"type":"item.completed","item":{"id":"i","type":"agent_message","text":"done"}}
    OUT
    assert_equal "t-1", harness("codex").session_id(output)
    assert_equal "done", harness("codex").result_text(output)
    assert harness("codex").stale_session?("thread/resume failed: no rollout found for thread id 0000")
  end

  def test_claude_usage_comes_from_the_result_event
    output = %({"result":"ok","session_id":"s","usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":9,"cache_creation_input_tokens":4}}\n)
    expected = { "input_tokens" => 25, "cached_input_tokens" => 9, "cache_write_input_tokens" => 4, "output_tokens" => 3 }
    assert_equal(expected, harness("claude").usage(output))
  end

  def test_codex_usage_adds_up_the_turns
    output = <<~OUT
      {"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2}}
      {"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":4}}
    OUT
    expected = { "input_tokens" => 12, "cached_input_tokens" => 1, "cache_write_input_tokens" => 0, "output_tokens" => 6 }
    assert_equal(expected, harness("codex").usage(output))
  end

  def test_hermes_usage_comes_from_the_result_event
    output = %({"type":"result","session_id":"s","usage":{"prompt_tokens":8,"completion_tokens":2}}\n)
    expected = { "input_tokens" => 8, "cached_input_tokens" => 0, "cache_write_input_tokens" => 0, "output_tokens" => 2 }
    assert_equal(expected, harness("hermes").usage(output))
  end

  def test_absent_usage_is_nil
    assert_nil harness("claude").usage(%({"result":"ok"}\n))
    assert_nil harness("codex").usage("")
    assert_nil harness("opencode").usage("x")
    assert_nil harness("opencode").context("x")
    assert_nil Dispatcher::Harness::Generic.usage("x")
  end

  # Captured from a real `opencode run --format json`, shortened.
  OPENCODE_STEPS = "\e]777;notify;warp://cli-agent;{\"event\":\"stop\"}\a" \
                   "{\"type\":\"step_finish\",\"timestamp\":1,\"sessionID\":\"ses_a\",\"part\":{\"type\":\"step-finish\"," \
                   "\"tokens\":{\"total\":23047,\"input\":21381,\"output\":2,\"reasoning\":0," \
                   "\"cache\":{\"write\":0,\"read\":1664}}}}\n" \
                   "{\"type\":\"step_finish\",\"timestamp\":2,\"sessionID\":\"ses_a\",\"part\":{\"type\":\"step-finish\"," \
                   "\"tokens\":{\"input\":100,\"output\":5,\"reasoning\":3,\"cache\":{\"write\":10,\"read\":23000}}}}\n"

  def test_opencode_usage_sums_the_steps
    expected = { "input_tokens" => 46_155, "cached_input_tokens" => 24_664, "cache_write_input_tokens" => 10,
                 "output_tokens" => 10 }
    assert_equal expected, harness("opencode").usage(OPENCODE_STEPS)
  end

  def test_opencode_context_is_the_input_of_the_last_step
    assert_equal 23_110, harness("opencode").context(OPENCODE_STEPS)
  end

  def test_opencode_command
    cmd = harness("opencode").build_command(config(model: "p/m"), "go", "ses_1")
    assert_equal %w[opencode run --format json --agent backend-developer], cmd.first(6)
    assert_includes pairs(cmd), ["--session", "ses_1"]
    assert_includes pairs(cmd), ["-m", "p/m"]
    assert_equal "go", cmd.last
  end
end

class PollerTest < Minitest::Test
  def setup
    skip "Taskwarrior ('task') not installed" unless system("task", "--version", out: File::NULL)

    @dir = Dir.mktmpdir("dispatcher-poller-test")
    @coord_dir = File.join(@dir, ".maf/coordination")
    @env = { "COORD_DIR" => @coord_dir, "TASKRC" => File.join(@coord_dir, "taskrc"),
             "COORD_ROLE" => "backend-developer", "COORD_WORKER" => "backend-1" }
    # The Poller shells out to `coord`, so it needs a coord executable in CWD.
    FileUtils.mkdir_p(File.join(@dir, ".maf", "bin"))
    FileUtils.cp(File.expand_path("../assets/coord", __dir__), File.join(@dir, ".maf", "bin", "coord"))
    FileUtils.chmod("+x", File.join(@dir, ".maf", "bin", "coord"))
    FileUtils.mkdir_p(File.join(@dir, ".maf", "lib", "maf"))
    FileUtils.cp_r(File.expand_path("../lib/maf/shared", __dir__), File.join(@dir, ".maf", "lib", "maf"))
    @original_dir = Dir.pwd
    Dir.chdir(@dir)
    Coord::CLI.new(["init"], env: @env).run
  end

  def teardown
    Dir.chdir(@original_dir) if @original_dir && Dir.exist?(@original_dir)
    FileUtils.remove_entry(@dir) if @dir
  end

  def poller = Dispatcher::Poller.new(@env, "backend-developer")

  def test_lists_unclaimed_task_ids
    id = capture_io do
      Coord::CLI.new(["add", "--role", "backend-developer", "--scope", "t/**", "--title", "Fix"], env: @env).run
    end.first.strip
    assert_equal [id], poller.unclaimed_task_ids
  end

  def test_lists_the_claimed_task_ids_of_this_worker
    id = capture_io do
      Coord::CLI.new(["add", "--role", "backend-developer", "--scope", "t/**", "--title", "Fix"], env: @env).run
    end.first.strip
    capture_io { Coord::CLI.new(["claim", id], env: @env).run }
    assert_equal [id], poller.claimed_task_ids
  end

  def test_no_tasks_gives_no_ids
    assert_empty poller.unclaimed_task_ids
  end

  # Two workers of one role race for one task. Only the first gets a run.
  def test_claim_first_gives_a_task_to_one_worker_only
    id = capture_io do
      Coord::CLI.new(["add", "--role", "backend-developer", "--scope", "t/**", "--title", "Fix"], env: @env).run
    end.first.strip
    other = Dispatcher::Poller.new(@env.merge("COORD_WORKER" => "backend-2"), "backend-developer")

    assert_equal id, poller.claim_first([id])
    assert_nil other.claim_first([id])
  end
end

# `maf retire` sends TERM to a detached dispatcher. The dispatcher must end
# its wait between cycles at once, not after the full poll interval.
class StopSignalTest < Minitest::Test
  def test_term_ends_the_poll_loop_without_waiting_for_the_interval
    dir = Dir.mktmpdir("dispatcher-stop-test")
    script = File.expand_path("../assets/dispatcher", __dir__)
    env = { "COORD_DIR" => dir, "DISPATCHER_LOG" => File.join(dir, "log") }
    pid = spawn(env, RbConfig.ruby, script, "tester", "--command", "true", "--interval", "600",
                "--no-poll-tasks", chdir: dir)
    sleep 1
    Process.kill("TERM", pid)
    _, status = Process.wait2(pid)

    assert status.success?
    assert_includes File.read(File.join(dir, "log")), "stopped (TERM)"
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end

class ReportBlockTest < Minitest::Test
  def parse(text) = Dispatcher::ReportBlock.parse(text)

  def test_absent_block_is_nil
    assert_nil parse("all done")
    assert_nil parse(nil)
  end

  def test_valid_block
    data = parse(%(text\n<report>{"status":"done","tests":"pass","next":"merge"}</report>)).data
    assert_equal "merge", data["next"]
  end

  def test_the_last_block_wins
    assert_equal "blocked", parse('<report>{"status":"done"}</report> <report>{"status":"blocked"}</report>').data["status"]
  end

  def test_escaped_block_inside_raw_json_output
    output = %({"type":"text","text":"x <report>{\\"status\\":\\"done\\"}</report>"})
    assert_equal "done", parse(output).data["status"]
  end

  def test_errors
    assert_match(/status must be one of/, parse('<report>{"status":"ok"}</report>').error)
    assert_match(/tests must be pass or fail/, parse('<report>{"status":"done","tests":"x"}</report>').error)
    assert_match(/needs tests pass/, parse('<report>{"status":"done","tests":"fail"}</report>').error)
    assert_match(/not a JSON object/, parse("<report>nope</report>").error)
  end

  # The prompt shows the format with placeholders. An echoed prompt must not pass.
  def test_the_format_example_is_invalid
    refute_nil parse(Dispatcher::ReportBlock::REPORT_FORMAT).error
  end
end

# LeadChores runs coord reap, and coord review-watch with a github section.
# Only the architect dispatcher does this.
class LeadChoresTest < Minitest::Test
  FakeCoord = Struct.new(:calls) do
    def coord(*args)
      calls << args
      true
    end
  end

  def setup
    @dir = File.realpath(Dir.mktmpdir("dispatcher-review-test"))
    system("git", "-C", @dir, "init", "-q")
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
  end

  def teardown = FileUtils.remove_entry(@dir)

  def calls(role, settings)
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(settings))
    poller = FakeCoord.new([])
    poll = Dispatcher::LeadChores.new(poller, role)
    Dir.chdir(@dir) { 2.times { poll.run } }
    poller.calls
  end

  def test_the_architect_runs_the_chores_once_per_period
    assert_equal [%w[reap], %w[review-watch --once]], calls("architect", github: { bot_user: "maf-bot" })
  end

  def test_no_review_poll_without_github_settings
    assert_equal [%w[reap]], calls("architect", {})
  end

  def test_no_poll_for_other_roles
    assert_empty calls("tester", github: { bot_user: "maf-bot" })
  end
end

# The run limit comes from --timeout, else from team.timeouts in
# .maf/config.json, else from the default.
class TimeoutTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("dispatcher-timeout-test"))
    system("git", "-C", @dir, "init", "-q")
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
  end

  def teardown = FileUtils.remove_entry(@dir)

  def timeout(*argv, team: nil)
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(team ? { team: team } : {}))
    Dir.chdir(@dir) { Dispatcher::Options.parse(argv + ["--no-skill"], { "COORD_DIR" => @dir }).timeout }
  end

  def test_the_default_timeout_is_1500_seconds
    assert_equal 1500, timeout("reviewer")
  end

  def test_the_team_section_sets_a_timeout_for_each_role
    assert_equal 2400, timeout("reviewer", team: { timeouts: { reviewer: 2400 } })
    assert_equal 1500, timeout("tester", team: { timeouts: { reviewer: 2400 } })
  end

  def test_the_flag_wins_over_the_team_section
    assert_equal 60, timeout("reviewer", "--timeout", "60", team: { timeouts: { reviewer: 2400 } })
  end

  def options(*argv, team: nil)
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(team ? { team: team } : {}))
    Dir.chdir(@dir) { Dispatcher::Options.parse(argv + ["--no-skill"], { "COORD_DIR" => @dir }) }
  end

  def test_the_team_section_sets_the_session_limits_of_a_role
    limits = { limits: { reviewer: { max_context: 80_000, max_session_runs: 1, cache_window: 120 } } }
    config = options("reviewer", "--harness", "codex", team: limits)
    assert_equal [80_000, 1, 120], [config.max_context, config.max_session_runs, config.cache_window]
    assert_equal [150_000, 5], options("tester", team: limits).then { [_1.max_context, _1.max_session_runs] }
  end

  def test_a_session_limit_flag_wins_over_the_team_section
    team = { limits: { reviewer: { max_context: 80_000 } } }
    assert_equal 60_000, options("reviewer", "--max-context", "60000", team: team).max_context
  end

  # A timed-out run tells the architect, because the task waits without a sign.
  def test_a_timeout_sends_a_message_to_the_architect
    calls = []
    runner = Dispatcher::Runner.new(Dispatcher::Config.new(role: "reviewer", worker: "reviewer-2", timeout: 1,
                                                           command: "sleep 5", coord_dir: @dir, cache_window: 0),
                                    Dispatcher::Harness.for(Dispatcher::Config.new(command: "sleep 5")), {})
    with_coord_calls(calls) { capture_io { runner.dispatch("work") } }

    assert_equal "architect", calls.first[3]
    assert_includes calls.first.last, "reviewer-2 timed out after 1s"
  end

  # Replaces CoordCall.run for the block and records each call.
  def with_coord_calls(calls)
    original = Dispatcher::CoordCall.method(:run)
    Dispatcher::CoordCall.define_singleton_method(:run) { |_env, *args| calls << args }
    yield
  ensure
    Dispatcher::CoordCall.define_singleton_method(:run, original)
  end
end

# An FYI message (coord msg --fyi) waits in the inbox and starts no run.
class FyiMailboxTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = Dir.mktmpdir("dispatcher-fyi-test")
    @mailbox = Dispatcher::Mailbox.new(@dir, "backend-developer")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_fyi_messages_alone_start_no_run
    write_message("backend-developer", "1.fyi.md", "architect", "note")
    assert_empty @mailbox.take
    assert_equal 1, inbox.size
  end

  def test_a_waking_message_takes_the_fyi_messages_along
    write_message("backend-developer", "1.fyi.md", "architect", "note")
    write_message("backend-developer", "2.md", "architect", "act")
    assert_equal %w[note act], @mailbox.take.map(&:text)
  end

  def test_the_prompt_marks_an_fyi_message
    write_message("backend-developer", "1.fyi.md", "architect", "note")
    write_message("backend-developer", "2.md", "architect", "act")
    prompt = Dispatcher::Prompt.messages(@mailbox.take, "backend-developer")
    assert_includes prompt, "message from architect (FYI: no reply needed)"
  end

  # A usage limit is no attempt: the name keeps no retry count.
  def test_restore_returns_messages_without_an_attempt
    write_message("backend-developer", "1.md", "architect", "act")
    @mailbox.restore(@mailbox.take)
    assert_equal ["1.md"], inbox.map { |path| File.basename(path) }
  end
end

class UsageLimitTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = Dir.mktmpdir("dispatcher-limit-test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  LIMIT = %(echo '{"type":"error","message":"You have hit your usage limit."}'; exit 1)

  def main(command) = Dispatcher::Main.new(config(command: command, poll_tasks: false, timeout: 5))
  def status = JSON.parse(File.read(File.join(@dir, "status", "backend-developer-bot.json")))

  def test_a_limit_returns_the_messages_and_pauses_new_runs
    write_message("backend-developer", "1.md", "architect", "first")
    calls = File.join(@dir, "calls")
    dispatcher = main("echo run >> #{calls}; #{LIMIT}")
    capture_io { 2.times { dispatcher.cycle } }
    assert_equal 1, File.readlines(calls).size
    assert_equal ["1.md"], inbox.map { |path| File.basename(path) }
    assert_equal "limited", status.dig("last_run", "outcome")
    assert status["paused_until"]
  end

  def test_the_pause_doubles_and_ends_on_another_outcome
    pause = Dispatcher::Pause.new
    now = Time.at(0)
    pause.start(now)
    assert_equal 900, (pause.until - now).to_i
    pause.start(now)
    assert_equal 1800, (pause.until - now).to_i
    assert pause.clear
    refute pause.clear
  end

  def test_the_text_of_a_successful_or_timed_out_run_is_no_limit
    limit = "rate limit\n"
    refute Dispatcher::UsageLimit.hit?(Dispatcher::Result.new(limit, false, true, :timeout))
    assert Dispatcher::UsageLimit.hit?(Dispatcher::Result.new(limit, false, false, :exit))
  end
end

# A dispatched Codex run starts without the user's extra tools. Only the
# graphify server of this project stays.
class CodexLeanTest < Minitest::Test
  include DispatcherTestHelpers

  def setup
    @dir = "/tmp"
  end

  def test_lean_flags_disable_features_and_foreign_mcp_servers
    Dir.mktmpdir do |home|
      toml = "[mcp_servers.devrelay-gateway]\n[mcp_servers.graphify-#{File.basename(Dispatcher::Project.root)}]\n"
      File.write(File.join(home, "config.toml"), toml)
      flags = with_env("CODEX_HOME" => home) { Dispatcher::Harness::Codex::Lean.flags }
      assert_includes flags.each_cons(2).to_a, %w[--disable plugins]
      assert_includes flags.each_cons(2).to_a, ["-c", "mcp_servers.devrelay-gateway.enabled=false"]
      refute(flags.any? { |flag| flag.include?("graphify") })
    end
  end

  def test_full_harness_keeps_the_user_setup
    command = Dispatcher::Harness::Codex.build_command(config(lean: false), "go", nil)
    refute_includes command, "--disable"
    assert Dispatcher::Options.parse(%w[tester --no-skill], { "COORD_DIR" => "/tmp/c" }).lean
    refute Dispatcher::Options.parse(%w[tester --no-skill --full-harness], { "COORD_DIR" => "/tmp/c" }).lean
  end

  # The Codex cache lasts minutes, the Claude Code cache 1 hour.
  def test_the_cache_window_default_depends_on_the_harness
    env = { "COORD_DIR" => "/tmp/c" }
    windows = %w[codex claude].map { |name| Dispatcher::Options.parse(%W[tester --no-skill --harness #{name}], env) }
    assert_equal [300, 3300], windows.map(&:cache_window)
    assert_equal 9, Dispatcher::Options.parse(%w[t --no-skill --harness codex --cache-window 9], env).cache_window
  end

  def test_a_claude_run_starts_without_user_skills_and_mcp_servers
    lean = Dispatcher::Harness::Claude.build_command(config(lean: true), "go", nil)
    full = Dispatcher::Harness::Claude.build_command(config(lean: false), "go", nil)
    assert_equal %w[--strict-mcp-config --disable-slash-commands], lean - full
    assert_equal %w[-- go], lean.last(2)
  end

  def with_env(values)
    old = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end
end

class LeadPrefetchTest < Minitest::Test
  GOAL = "c1ab3a20-3f47-440e-92d8-62f15de77ef5"
  Poller = Struct.new(:coord_dir) do
    def goal_ids = [GOAL]
  end

  def test_a_lead_run_gets_the_artifact_list_with_sizes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "artifacts", GOAL))
      File.write(File.join(dir, "artifacts", GOAL, "plan.md"), "x" * 2048)
      context = Dispatcher::Prefetch.context(Poller.new(dir), nil, lead: true)
      assert_includes context, "$ artifacts of the open goals\n#{GOAL}/plan.md 2.0k"
      refute_includes Dispatcher::Prefetch.context(Poller.new(dir)), "artifacts"
    end
  end

  def test_the_lead_prompt_limits_reads_and_acknowledgements
    prompt = Dispatcher::Prompt.messages([Dispatcher::Message.new("p", "project-manager", "x")], "architect")
    assert_includes prompt, "Never print a whole artifact folder"
    assert_includes prompt, "Do not send a message only to acknowledge"
  end
end

class PeakRateTest < Minitest::Test
  include DispatcherTestHelpers

  # 2026-10-07 is a Wednesday, 2026-10-10 a Saturday.
  def at(text) = Time.utc(*text.split(/[- :]/).map(&:to_i))

  def test_notice_for_deepseek_on_opencode_at_peak
    cfg = config(harness: "opencode", model: "deepseek/deepseek-flash")
    assert_includes Dispatcher::PeakRate.notice(cfg, at("2026-10-07 07:30")), "DeepSeek peak hours (07:30 UTC)"
    assert_nil Dispatcher::PeakRate.notice(cfg, at("2026-10-07 12:00"))
    assert_nil Dispatcher::PeakRate.notice(config(harness: "claude", model: "deepseek"), at("2026-10-07 07:30"))
  end

  def test_the_agent_file_names_the_model
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".opencode/agents")
        File.write(".opencode/agents/backend-developer.md", "---\nmode: all\nmodel: deepseek/x\n---\nmodel: other\n")
        assert_equal "deepseek/x", Dispatcher::OpencodeModel.for(config)
      end
    end
  end
end
