# frozen_string_literal: true

# cursor_test.rb - tests for lib/maf/shared/harnesses/cursor.rb.
require_relative "helper"

class CursorHarnessTest < Minitest::Test
  include HarnessTestHelpers

  HARNESS = "cursor"

  # The Cursor CLI has no agent flag: a fresh session gets the role file body.
  def test_a_fresh_run_gets_the_role_file_without_its_front_matter
    in_tmpdir do
      write(".maf/agents/cursor/backend-developer.md", "---\nname: backend-developer\n---\n\nROLE")
      assert_equal %w[agent -p --output-format json --force], harness.build_command(config, "go", nil).first(5)
      assert_equal "ROLE\n\ngo", harness.build_command(config, "go", nil).last
    end
  end

  def test_a_resumed_run_gets_only_the_prompt
    assert_equal ["--resume", "c-1", "go"], harness.build_command(config, "go", "c-1").last(3)
  end

  OUTPUT = %({"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"c-1"}\n)

  def test_output
    assert_equal %w[c-1 done], [harness.session_id(OUTPUT), harness.result_text(OUTPUT)]
    assert_nil harness.usage(OUTPUT)
  end

  # A failed run prints no JSON. "not found" in a run with a result is not a stale session.
  def test_a_stale_session_has_no_result
    refute harness.stale_session?(OUTPUT.sub("done", "file not found"))
    assert harness.stale_session?("Error: chat c-1 not found")
  end

  def test_launch_names_the_role_file
    command = harness.launch("tester", "gpt-5")
    assert_equal %w[agent --model gpt-5], command.first(3)
    assert_includes command.last, ".maf/agents/cursor/tester.md"
  end

  # The binary is `agent`, not the harness name.
  def test_the_command_is_agent
    assert_equal "agent", harness.command
  end

  # Cursor rejects MODEL[effort=L] and has no effort flag. The model name carries the level.
  def test_the_effort_goes_into_the_model_name
    assert_equal %w[agent --model gpt-5-high], harness.launch("tester", "gpt-5", "high").first(3)
    assert_equal %w[agent --model gpt-5], harness.launch("tester", "gpt-5").first(3)
    assert_includes pairs(harness.build_command(config(model: "m-fast", effort: "low"), "go", nil)),
                    %w[--model m-low-fast]
  end

  LIST = "Available models\n\nauto - Auto (current, default)\ngpt-c-low - C Low\ngpt-c - C\n" \
         "gpt-c-high-fast - C High Fast\nopus-thinking-high - Opus\nopus-thinking-xhigh - Opus XH\n"

  def test_lists_each_model_without_its_level
    with_models do
      assert_equal %w[auto gpt-c gpt-c-fast opus-thinking], harness.models
      assert_equal([%w[low], %w[high], %w[high xhigh], [], []],
                   %w[gpt-c gpt-c-fast opus-thinking auto opus-thinking-high].map { |m| harness.efforts(m) })
    end
  end

  # opus-thinking is not a model name by itself. Only opus-thinking-high is.
  def test_a_model_without_its_own_name_needs_a_level
    with_models do
      assert harness.known_model?("opus-thinking-high")
      assert harness.effort_required?("opus-thinking")
      refute harness.effort_required?("gpt-c")
    end
  end

  # A name with a level gets the new level, not a second one. Without a model, the level is lost.
  def test_a_new_level_replaces_the_level_in_the_name
    assert_equal %w[agent --model m-low-fast], harness.launch("tester", "m-high-fast", "low").first(3)
    _, err = capture_io { harness.launch("tester", nil, "high") }
    assert_includes err, "maf drops --effort"
  end

  def test_the_role_file_names_the_model_with_its_level
    values = { role: "r", description: "d", can_edit: true, project: "/p", prompt: "P" }
    assert_includes harness.render_role(**values, model: "gpt-c", effort: "high"), "model: gpt-c-high\n"
  end

  def with_models(&block)
    Dir.mktmpdir do |bin|
      fake_agent(bin)
      with_env("PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}", &block)
    end
  end

  def teardown = forget_models

  def fake_agent(bin)
    forget_models
    File.write(File.join(bin, "agent"), "#!/bin/sh\nprintf '#{LIST}'\n")
    File.chmod(0o755, File.join(bin, "agent"))
  end

  def forget_models
    models = Maf::Shared::Harnesses::CursorModels
    models.remove_instance_variable(:@listed) if models.instance_variable_defined?(:@listed)
  end
end
