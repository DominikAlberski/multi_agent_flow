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
end
