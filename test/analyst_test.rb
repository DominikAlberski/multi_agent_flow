#!/usr/bin/env ruby
# frozen_string_literal: true

# test/analyst_test.rb - tests for assets/analyst.
#
# Run: ruby test/analyst_test.rb
#
# A shell script plays the model. A fake HOME holds the session transcripts.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
# `analyst` has no .rb suffix, so `require` cannot find it.
load File.expand_path("../assets/analyst", __dir__)

class AnalystTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("analyst-test")
    @coord = File.join(@dir, ".maf", "coordination")
    FileUtils.mkdir_p(File.join(@coord, "usage"))
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_a_call_gets_the_kind_of_the_command_after_the_setup
    assert_equal "grep", Analyst.call("bash", "cd app && grep -rn foo .", 10).kind
    assert_equal "vault", Analyst.call("bash", "source .maf/env.sh; vault age", 10).kind
    assert_equal "read", Analyst.call("Read", nil, 10).kind
  end

  def test_hints_come_from_a_fenced_reply_and_keep_only_known_integer_limits
    reply = "```json\n{\"hints\":[{\"text\":\"Cap it.\",\"limits\":{\"max_context\":80000,\"rm\":1}}," \
            "{\"text\":\"Bad.\",\"limits\":{\"max_session_runs\":\"1\"}},{\"text\":\"\"}," \
            "{\"text\":\"c\"},{\"text\":\"d\"}]}\n```"
    hints = Analyst::Model.hints(reply)
    assert_equal [{ "text" => "Cap it.", "limits" => { "max_context" => 80_000 } }, { "text" => "Bad." }], hints
  end

  # opencode prints a terminal notify line with its own JSON before the reply.
  def test_hints_skip_other_json_in_front_of_the_reply
    notify = JSON.generate("v" => 1, "response" => '{"hints":[]}')
    reply = "\e]777;notify;warp://cli-agent;#{notify}\a{\"hints\":[{\"text\":\"ok\"}]}"
    assert_equal [{ "text" => "ok" }], Analyst::Model.hints(reply)
  end

  def test_a_reply_without_json_is_an_error
    error = assert_raises(RuntimeError) { Analyst::Model.hints("no idea") }
    assert_includes error.message, "the model returned no JSON"
  end

  def fake_model(reply)
    path = File.join(@dir, "model")
    File.write(path, "#!/bin/sh\ncat > #{@dir}/prompt\nprintf '%s' '#{JSON.generate(reply)}'\n")
    FileUtils.chmod(0o755, path)
    File.write(File.join(@dir, ".maf", "config.json"), JSON.generate(team: { analyst: { command: [path] } }))
  end

  def written = JSON.parse(File.read(File.join(@coord, "hints", "w-bot.json")))

  def test_main_writes_the_hints_and_the_cost
    fake_model("result" => '{"hints":[{"text":"Start fresh.","limits":{"max_session_runs":1}}]}',
               "total_cost_usd" => 0.002)
    Analyst::Main.new(["w-bot", "--coord", @coord]).run
    assert_equal [[{ "text" => "Start fresh.", "limits" => { "max_session_runs" => 1 } }], 0.002],
                 written.values_at("hints", "cost_usd")
  end

  def test_the_prompt_holds_the_run_history
    File.write(File.join(@coord, "usage", "w-bot.runs.jsonl"),
               "#{JSON.generate("session_run" => 2, "input_tokens" => 900, "limits" => { "max_context" => 1 })}\n")
    fake_model("result" => '{"hints":[]}')
    Analyst::Main.new(["w-bot", "--coord", @coord]).run
    prompt = File.read(File.join(@dir, "prompt"))
    assert_includes prompt, "Find at most 3 problems"
    assert_includes prompt, "\"input_tokens\": 900"
  end

  def test_a_failed_model_call_is_written_as_the_error
    fake_model({})
    File.write(File.join(@dir, "model"), "#!/bin/sh\necho quota exceeded; exit 1\n")
    Analyst::Main.new(["w-bot", "--coord", @coord]).run
    assert_includes written["error"], "quota exceeded"
  end

  # Claude Code transcript: a tool_use block, then a tool_result block with the same ID.
  def test_the_digest_counts_the_tool_calls_of_a_claude_session
    projects = File.join(@dir, "home", ".claude", "projects", "p")
    FileUtils.mkdir_p(projects)
    use = { "message" => { "content" => [{ "type" => "tool_use", "id" => "u1", "name" => "Bash",
                                           "input" => { "command" => "grep -rn x ." } }] } }
    block = { "type" => "tool_result", "tool_use_id" => "u1", "content" => "x" * 50 }
    result = { "message" => { "content" => [block] } }
    File.write(File.join(projects, "s-1.jsonl"), [use, result].map { JSON.generate(_1) }.join("\n"))
    File.write(File.join(@coord, "workers.json"), JSON.generate("w-bot" => { "harness" => "claude" }))
    FileUtils.mkdir_p(File.join(@coord, "status"))
    File.write(File.join(@coord, "status", "w-bot.json"), JSON.generate("session_id" => "s-1"))
    tools = with_home(File.join(@dir, "home")) { Analyst::Digest.new(@coord, "w-bot").to_h[:tools] }
    assert_equal [1, 50, { "grep" => 1 }], tools.values_at(:calls, :output_chars, :by_kind)
  end

  def with_home(dir)
    old = ENV["HOME"]
    ENV["HOME"] = dir
    yield
  ensure
    ENV["HOME"] = old
  end
end
