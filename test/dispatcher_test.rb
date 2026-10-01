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
                 cache_window: 3300, coord_dir: @dir, worker: "backend-developer-bot", poll_tasks: true }
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
    capture_io { assert runner("echo session=new-1").dispatch("go") }
    assert_equal "new-1", session.id
  end

  def test_stale_session_retries_once_with_a_fresh_session
    session.save("old")
    script = %(echo "$1" >> #{@calls}; [ "$1" = old ] && { echo "Session not found: old"; exit 1; }; echo session=new-2)
    capture_io { assert runner(script).dispatch("go") }
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
    assert_includes prompt, "overwrite #{session.handoff_path}"
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
    capture_io { assert runner(reply("ok #{DONE}")).dispatch("go") }
    assert_equal [""], calls
  end

  # An agent that gives up but exits 0 must not count as done.
  def test_report_blocked_is_no_success_and_keeps_the_session
    blocked = '<report>{"status":"blocked","next":"ask the architect"}</report>'
    out, err = capture_io { refute runner(reply("stuck #{blocked}")).dispatch("go") }
    assert_equal "s-1", session.id
    assert_includes out + err, "status blocked"
  end

  def test_report_needs_review_is_no_success
    capture_io { refute runner(reply('<report>{"status":"needs_review"}</report>')).dispatch("go") }
  end

  def test_missing_block_resumes_the_session_once_then_counts_the_exit_status
    capture_io { assert runner(reply("no block")).dispatch("go") }
    assert_equal ["", "s-1"], calls
  end

  def test_invalid_block_resumes_once_then_fails
    capture_io { refute runner(reply('<report>{"status":"maybe"}</report>')).dispatch("go") }
    assert_equal ["", "s-1"], calls
  end

  def test_retry_prompt_names_the_validation_error
    script = %(echo session=s-1; printf '%s' "$2" >> #{@calls}.prompt; printf 'reply: <report>{"status":"x"}</report>')
    capture_io { runner(script).dispatch("go") }
    assert_includes File.read("#{@calls}.prompt"), "Your report block is invalid: status must be one of"
  end

  # A custom command has no session, so the runner cannot resume it.
  def test_missing_block_without_a_session_counts_the_exit_status
    capture_io { assert runner(%(echo x >> #{@calls}; printf 'reply: plain')).dispatch("go") }
    assert_equal ["x"], calls
  end

  def test_abort_signal_fails_the_run_and_logs_it
    runner = Dispatcher::Runner.new(config(command: "echo GIVE-UP", timeout: 5, abort_signal: "GIVE-UP"), FakeHarness, {})
    out, err = capture_io { refute runner.dispatch("go") }
    assert_includes out + err, "sent the abort signal"
  end

  def with_verify(command, &block)
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(verify: command))
    Dir.chdir(@dir, &block)
  end

  def test_failing_verify_command_makes_a_done_run_no_success
    with_verify("echo broken; exit 1") do
      out, err = capture_io { refute runner(reply("ok #{DONE}")).dispatch("go") }
      assert_includes out + err, "verify command failed (echo broken; exit 1): broken"
    end
  end

  def test_passing_verify_command_keeps_the_success
    with_verify("true") { capture_io { assert runner(reply("ok #{DONE}")).dispatch("go") } }
  end

  def test_a_lead_role_gets_no_verify_check
    with_verify("exit 1") do
      lead = Dispatcher::Runner.new(config(role: "architect", command: reply("ok #{DONE}"), timeout: 5), FakeHarness, {})
      capture_io { assert lead.dispatch("go") }
    end
  end

  def usage_totals = JSON.parse(File.read(File.join(@dir, "usage", "backend-developer-bot.json")))

  def test_token_usage_adds_up_per_worker
    2.times { capture_io { runner("echo tokens=10").dispatch("go") } }
    assert_equal({ "input_tokens" => 20, "output_tokens" => 2, "runs" => 2 }, usage_totals)
  end

  def test_a_run_without_usage_writes_nothing
    capture_io { assert runner("echo plain").dispatch("go") }
    refute File.exist?(File.join(@dir, "usage"))
  end

  def test_a_broken_usage_file_never_fails_the_run
    FileUtils.mkdir_p(File.join(@dir, "usage"))
    File.write(File.join(@dir, "usage", "backend-developer-bot.json"), "{broken")
    capture_io { assert runner("echo tokens=10").dispatch("go") }
  end

  def test_handoff_note_drops_the_report_block
    capture_io { runner(reply("state #{DONE}")).dispatch("go") }
    assert_equal "state", session.handoff
  end

  # Regression: any non-zero exit cleared the session and re-ran the agent,
  # losing context and doubling the cost.
  def test_other_failures_keep_the_session_and_do_not_retry
    session.save("old")
    capture_io { refute runner(%(echo "$1" >> #{@calls}; echo "rate limited"; exit 1)).dispatch("go") }
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

  FakePoller = Struct.new(:ids) do
    def unclaimed_task_ids = ids
    def next_output = ids.join("\n")
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

  FakeBoard = Struct.new(:text) do
    def unclaimed_task_ids = []
    def next_output = text
  end

  def prompt_of_one_run(board)
    write_message("backend-developer", "1.md", "architect", "first")
    calls = File.join(@dir, "calls")
    main = Dispatcher::Main.new(config(command: "echo %{prompt} >> #{calls}", poll_tasks: false, timeout: 5))
    main.instance_variable_set(:@poller, board)
    _out, err = capture_io { main.cycle }
    [File.read(calls), err]
  end

  def test_prompt_gets_the_board_and_the_git_log
    prompt, = prompt_of_one_run(FakeBoard.new("abc\tfix login\n"))
    assert_includes prompt, "$ coord next backend-developer\nabc\tfix login"
    assert_includes prompt, "$ git log --oneline -10\n"
  end

  def test_prefetch_text_is_bounded
    prompt, = prompt_of_one_run(FakeBoard.new("x" * 5000))
    assert_includes prompt, "[cut at #{Dispatcher::Prefetch::LIMIT} characters]"
    refute_includes prompt, "x" * (Dispatcher::Prefetch::LIMIT + 1)
  end

  def test_a_failed_prefetch_is_logged_and_the_run_goes_on
    prompt, err = Dir.chdir(@dir) { prompt_of_one_run(FakeBoard.new(nil)) }
    assert_includes err, "prefetch failed: coord next backend-developer"
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
    assert_equal 300, config.timeout
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
    assert_includes prompt, "AGENTS.md"
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

  def test_tasks_prompt_names_the_role
    assert_includes Dispatcher::Prompt.tasks("tester"), "role tester"
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
    output = %({"result":"ok","session_id":"s","usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":9}}\n)
    assert_equal({ "input_tokens" => 12, "output_tokens" => 3 }, harness("claude").usage(output))
  end

  def test_codex_usage_adds_up_the_turns
    output = <<~OUT
      {"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2}}
      {"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":4}}
    OUT
    assert_equal({ "input_tokens" => 12, "output_tokens" => 6 }, harness("codex").usage(output))
  end

  def test_hermes_usage_comes_from_the_result_event
    output = %({"type":"result","session_id":"s","usage":{"prompt_tokens":8,"completion_tokens":2}}\n)
    assert_equal({ "input_tokens" => 8, "output_tokens" => 2 }, harness("hermes").usage(output))
  end

  def test_absent_usage_is_nil
    assert_nil harness("claude").usage(%({"result":"ok"}\n))
    assert_nil harness("codex").usage("")
    assert_nil harness("opencode").usage("x")
    assert_nil Dispatcher::Harness::Generic.usage("x")
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

  def test_no_tasks_gives_no_ids
    assert_empty poller.unclaimed_task_ids
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
