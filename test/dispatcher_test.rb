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
    def self.result_text(_output) = "ok"
  end

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
    File.write(File.join(@dir, ".agent-flow.json"), JSON.generate(MANIFEST))
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
    @coord_dir = File.join(@dir, "coordination")
    @env = { "COORD_DIR" => @coord_dir, "TASKRC" => File.join(@coord_dir, "taskrc"),
             "COORD_ROLE" => "backend-developer", "COORD_WORKER" => "backend-1" }
    # The Poller shells out to `coord`, so it needs a coord executable in CWD.
    FileUtils.cp(File.expand_path("../assets/coord", __dir__), File.join(@dir, "coord"))
    FileUtils.chmod("+x", File.join(@dir, "coord"))
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
