# frozen_string_literal: true

# claude_test.rb - tests for lib/maf/shared/harnesses/claude.rb.
require_relative "helper"

class ClaudeHarnessTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "claude"

  def test_a_fresh_run_names_the_agent_and_the_model
    fresh = harness.build_command(config(model: "haiku"), "go", nil)
    assert_equal %w[claude -p --output-format json], fresh.first(4)
    assert_includes pairs(fresh), ["--agent", "backend-developer"]
    assert_includes pairs(fresh), ["--model", "haiku"]
    refute_includes fresh, "--resume"
  end

  def test_a_run_resumes_a_session
    assert_includes pairs(harness.build_command(config, "go", "s-1")), ["--resume", "s-1"]
  end

  # The flow keeps its MCP config in .maf/mcp/, next to the coordination folder.
  # --mcp-config takes many values, so -- keeps the prompt out.
  def test_a_dispatched_run_gets_the_mcp_config_of_the_flow
    Dir.mktmpdir do |root|
      write(File.join(root, "mcp", "claude.json"), "{}")
      command = harness.build_command(config(coord_dir: File.join(root, "coordination")), "go", nil)
      assert_equal ["--mcp-config", File.join(root, "mcp", "claude.json"), "--", "go"], command.last(4)
    end
  end

  def test_a_run_starts_without_user_skills_and_mcp_servers
    lean = harness.build_command(config(lean: true), "go", nil)
    full = harness.build_command(config(lean: false), "go", nil)
    assert_equal %w[--strict-mcp-config --disable-slash-commands], lean - full
  end

  def test_output
    output = %({"type":"result","subtype":"success","result":"ok","session_id":"b847"}\n)
    assert_equal %w[b847 ok], [harness.session_id(output), harness.result_text(output)]
    assert harness.stale_session?("No conversation found with session ID: 0000")
  end

  USAGE = %({"result":"ok","session_id":"s","usage":{"input_tokens":12,"output_tokens":3,) +
          %("cache_read_input_tokens":9,"cache_creation_input_tokens":4}}\n)

  def test_usage_comes_from_the_result_event
    assert_equal usage(25, 9, 4, 3), harness.usage(USAGE)
    assert_nil harness.usage(%({"result":"ok"}\n))
  end

  # The project's harness config stays as it is. The flow passes its own files at the start.
  def test_launch_passes_the_settings_and_the_mcp_config_of_the_flow
    in_tmpdir do |dir|
      %w[claude/settings.json mcp/claude.json].each { |rel| write(File.join(".maf", rel), "{}") }
      expected = ["--settings", "#{dir}/.maf/claude/settings.json", "--mcp-config", "#{dir}/.maf/mcp/claude.json"]
      assert_equal expected, harness.launch("tester", nil)[1, 4]
    end
  end

  def test_accepts_aliases_and_full_ids
    %w[opus sonnet[1m] opusplan claude-sonnet-5-5 claude-opus-5-5[1m] us.anthropic.claude-haiku-5-5-v1:0]
      .each { |name| assert harness.known_model?(name), name }
  end

  # The typo that stopped a tester: every dispatched run failed with unrecognized_model.
  def test_rejects_a_misspelled_family
    refute harness.known_model?("claude-sonet-5-5")
    refute harness.known_model?("sonet")
  end

  def test_only_the_architect_gets_the_schedule_wakeup_rule
    assert_includes harness.architect_rule, "ScheduleWakeup"
    assert_nil harness("codex").architect_rule
  end

  def test_the_effort_goes_to_the_run_and_the_launch
    assert_includes pairs(harness.build_command(config(effort: "high"), "go", nil)), ["--effort", "high"]
    assert_includes pairs(in_tmpdir { harness.launch("tester", nil, "max") }), ["--effort", "max"]
    refute_includes harness.build_command(config, "go", nil), "--effort"
  end

  def test_the_effort_levels
    assert harness.known_effort?("xhigh")
    refute harness.known_effort?("ultra")
  end
end
