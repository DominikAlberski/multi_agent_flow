# frozen_string_literal: true

# opencode_test.rb - tests for lib/maf/shared/harnesses/opencode.rb.
require_relative "helper"

class OpencodeHarnessTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "opencode"

  def test_command
    cmd = harness.build_command(config(model: "p/m"), "go", "ses_1")
    assert_equal %w[opencode run --format json --agent backend-developer], cmd.first(6)
    assert_includes pairs(cmd), ["--session", "ses_1"]
    assert_includes pairs(cmd), ["-m", "p/m"]
    assert_equal "go", cmd.last
  end

  # The flow keeps its MCP config in .maf/mcp/. opencode reads it from OPENCODE_CONFIG.
  def test_a_dispatched_run_gets_the_mcp_config_of_the_flow
    Dir.mktmpdir do |root|
      write(File.join(root, "mcp", "opencode.json"), "{}")
      env = harness.run_env(config(coord_dir: File.join(root, "coordination")))
      assert_equal File.join(root, "mcp", "opencode.json"), env["OPENCODE_CONFIG"]
    end
  end

  # Captured from a real `opencode run --format json`: an escape-code prefix,
  # and a JSON event glued onto the end of a notify line.
  GLUED = "\e]777;notify;warp://cli-agent;{\"event\":\"prompt_submit\",\"session_id\":\"ses_other\"}" \
          "{\"type\":\"error\",\"timestamp\":1790174271790,\"sessionID\":\"ses_abc\",\"error\":{}}\n"

  def test_id_comes_from_an_event_even_when_glued
    assert_equal "ses_abc", harness.session_id(GLUED)
    assert_nil harness.session_id(%(note: "sessionID":"fake"\n))
  end

  # Captured from a real `opencode run --format json`, shortened.
  STEPS = "\e]777;notify;warp://cli-agent;{\"event\":\"stop\"}\a" \
          "{\"type\":\"step_finish\",\"timestamp\":1,\"sessionID\":\"ses_a\",\"part\":{\"type\":\"step-finish\"," \
          "\"tokens\":{\"total\":23047,\"input\":21381,\"output\":2,\"reasoning\":0," \
          "\"cache\":{\"write\":0,\"read\":1664}}}}\n" \
          "{\"type\":\"step_finish\",\"timestamp\":2,\"sessionID\":\"ses_a\",\"part\":{\"type\":\"step-finish\"," \
          "\"tokens\":{\"input\":100,\"output\":5,\"reasoning\":3,\"cache\":{\"write\":10,\"read\":23000}}}}\n"

  def test_usage_sums_the_steps
    expected = { "input_tokens" => 46_155, "cached_input_tokens" => 24_664, "cache_write_input_tokens" => 10,
                 "output_tokens" => 10 }
    assert_equal expected, harness.usage(STEPS)
    assert_nil harness.usage("x")
  end

  def test_context_is_the_input_of_the_last_step
    assert_equal 23_110, harness.context(STEPS)
    assert_nil harness.context("x")
  end

  def test_deepseek_runs_at_the_peak_rate
    assert harness.peak_rate?(config(model: "deepseek/deepseek-flash"))
    refute harness.peak_rate?(config(model: "openrouter/qwen3-coder"))
    refute harness("claude").peak_rate?(config(model: "deepseek"))
  end

  def test_the_agent_file_names_the_model
    in_tmpdir do
      write(".opencode/agents/backend-developer.md", "---\nmode: all\nmodel: deepseek/x\n---\nmodel: other\n")
      assert_equal "deepseek/x", harness.configured_model(config)
    end
  end

  def test_the_effort_is_the_variant
    assert_includes pairs(harness.build_command(config(effort: "high"), "go", nil)), ["--variant", "high"]
    refute_includes harness.build_command(config, "go", nil), "--variant"
  end

  # The TUI has no variant flag, so the agent file carries it.
  def test_the_agent_file_names_the_variant
    values = { role: "r", description: "d", can_edit: true, project: "/p", prompt: "P", model: nil }
    assert_includes harness.render_role(**values, effort: "max"), "variant: max\n"
    refute_includes harness.render_role(**values), "variant:"
  end

  # The TUI cannot take the level, so maf names the key that changes it in the session.
  def test_launch_with_another_effort_names_the_tui_key
    err = launch_err("high", "max")
    assert_includes err, "starts with variant high"
    assert_includes err, "ctrl+t"
    assert_includes err, "maf add opencode:r --effort r=max"
  end

  def test_launch_with_the_saved_effort_or_none_is_silent
    assert_empty launch_err("high", "high")
    assert_empty launch_err("high", nil)
  end

  def launch_err(saved, effort)
    in_tmpdir do
      write(".opencode/agents/r.md", "---\nmode: primary\nvariant: #{saved}\n---\n\nP")
      capture_io { harness.launch("r", nil, effort) }.last
    end
  end
end
