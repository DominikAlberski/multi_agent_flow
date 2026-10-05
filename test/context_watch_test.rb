#!/usr/bin/env ruby
# frozen_string_literal: true

# test/context_watch_test.rb - tests for the context-watch hook.
#
# Run: ruby test/context_watch_test.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
load File.expand_path("../assets/harness-hooks/context-watch.rb", __dir__)

class ContextWatchTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("context-watch-test")
    @coord = File.join(@dir, ".maf", "coordination")
    @transcript = File.join(@dir, "session.jsonl")
    @env = { "COORD_DIR" => @coord, "COORD_WORKER" => "architect-1", "COORD_ROLE" => "architect",
             "MAF_CONTEXT_LIMIT" => "1000" }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def claude_line(id, context, output = 5)
    usage = { input_tokens: 2, cache_read_input_tokens: context - 2, cache_creation_input_tokens: 0,
              output_tokens: output }
    JSON.generate(type: "assistant", message: { id: id, model: "claude-opus-5-5", usage: usage })
  end

  def codex_line(input, cached, output, last)
    total = { input_tokens: input, cached_input_tokens: cached, output_tokens: output }
    info = { total_token_usage: total, last_token_usage: { input_tokens: last }, model_context_window: 258_400 }
    JSON.generate(type: "event_msg", payload: { type: "token_count", info: info })
  end

  def append(*lines) = File.open(@transcript, "a") { |file| lines.each { |line| file.puts(line) } }
  def stop(path = @transcript) = ContextWatch::Hook.new({ "hook_event_name" => "Stop", "transcript_path" => path,
                                                          "session_id" => "s1" }, @env).run
  def status = JSON.parse(File.read(File.join(@coord, "status", "architect-1.json")))
  def usage = JSON.parse(File.read(File.join(@coord, "usage", "architect-1.json")))
  def handoff = File.join(@coord, "sessions", "architect-1.handoff.md")

  def test_a_stop_records_the_model_the_context_and_the_usage
    append(claude_line("m1", 400), claude_line("m2", 600))

    assert_nil stop
    assert_equal ["claude-opus-5-5", 600, "interactive"], status.values_at("model", "context_tokens", "mode")
    assert_equal 1000, usage["input_tokens"]
  end

  # Claude Code writes one line per content block, each with the same usage.
  def test_a_message_id_counts_once
    append(claude_line("m1", 400), claude_line("m1", 400))
    stop

    assert_equal 400, usage["input_tokens"]
  end

  def test_a_second_stop_reads_only_the_new_lines
    append(claude_line("m1", 400))
    stop
    append(claude_line("m2", 500))
    stop

    assert_equal 900, usage["input_tokens"]
  end

  def test_over_the_limit_asks_for_the_note_once_then_tells_the_user
    append(claude_line("m1", 1500))
    first = stop
    second = stop

    assert_equal "block", first[:decision]
    assert_includes first[:reason], handoff
    assert_includes second[:systemMessage], "Type /clear to restart"
  end

  def test_the_new_session_gets_the_handoff_note
    FileUtils.mkdir_p(File.dirname(handoff))
    File.write(handoff, "Goal 3 is half done.")
    output = ContextWatch::Hook.new({ "hook_event_name" => "SessionStart", "session_id" => "s2" }, @env).run

    assert_includes output.dig(:hookSpecificOutput, :additionalContext), "Goal 3 is half done."
  end

  def test_the_project_config_sets_the_limit
    @env.delete("MAF_CONTEXT_LIMIT")
    File.write(File.join(@dir, ".maf", "config.json").tap { |p| FileUtils.mkdir_p(File.dirname(p)) },
               JSON.generate(team: { context_limit: 300 }))
    append(claude_line("m1", 400))

    assert_equal "block", stop[:decision]
  end

  # Codex writes cumulative totals. A resumed session must not count them twice.
  def test_codex_usage_is_the_change_of_the_total
    path = File.join(@dir, ".codex", "rollout.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    model = JSON.generate(type: "turn_context", payload: { model: "gpt-6.1-sol" })
    File.write(path, "#{model}\n#{codex_line(100, 60, 5, 100)}\n")
    stop(path)
    File.write(path, "#{codex_line(250, 160, 9, 150)}\n", mode: "a")
    stop(path)

    assert_equal [250, 160, 9], usage.values_at("input_tokens", "cached_input_tokens", "output_tokens")
    fields = status.values_at("model", "context_tokens", "context_window", "harness")
    assert_equal ["gpt-6.1-sol", 150, 258_400, "codex"], fields
  end
end
