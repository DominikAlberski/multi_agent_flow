# frozen_string_literal: true

# contract_test.rb - every harness in lib/maf/shared/harnesses/ keeps the
# interface of Harness::Base. A new harness file runs these tests unchanged.
require_relative "helper"

class HarnessContractTest < Minitest::Test
  include HarnessTestHelpers

  HARNESSES = Maf::Shared::Harness.all
  FILES = Dir[File.expand_path("../../lib/maf/shared/harnesses/*.rb", __dir__)].map { |f| File.basename(f, ".rb") }
  VALUES = { role: "tester", title: "Tester", description: "Tests things.", project: "/p", prompt: "PROMPT" }.freeze

  def each_harness = HARNESSES.each { |harness| in_tmpdir { yield harness } }

  def test_each_file_registers_one_harness_with_its_name
    assert_equal FILES.sort, Maf::Shared::Harness.names
  end

  def test_the_role_file_carries_the_marker_and_the_prompt
    HARNESSES.product([true, false], ["m-1", nil]).each do |harness, can_edit, model|
      text = harness.render_role(**VALUES, can_edit: can_edit, model: model)
      assert_includes text, Maf::Flow::RoleFiles::MARKER, harness.name
      assert_includes text, "PROMPT", harness.name
    end
  end

  def test_the_role_path_is_in_the_folder_of_the_harness
    HARNESSES.select(&:role_dir).each do |harness|
      assert_equal ".maf/agents/#{harness.name}/tester.md", harness.role_path("tester")
    end
  end

  def run_command(harness, session)
    harness.build_command(harness.prepare(config(model: "m-1", lean: true)), "PROMPT", session)
  end

  def test_a_run_command_is_a_list_of_strings_with_the_prompt
    each_harness do |harness|
      cmds = [nil, "s-1"].map { |session| run_command(harness, session) }
      assert(cmds.flatten.all?(String), "#{harness.name}: #{cmds.inspect}")
      assert(cmds.all? { |cmd| cmd.any? { |part| part.include?("PROMPT") } }, harness.name)
    end
  end

  def launch_command(harness)
    write(harness.role_path("tester"), "ROLE") if harness.role_path("tester")
    cmd = nil
    capture_io { cmd = harness.launch("tester", "m-1") }
    cmd
  end

  def test_a_launch_command_is_a_list_of_strings
    each_harness do |harness|
      assert(launch_command(harness).all?(String), harness.name)
      assert_kind_of Hash, harness.launch_env
    end
  end

  def test_the_parsers_accept_empty_and_broken_output
    HARNESSES.product(["", "not json\n{broken"]).each do |harness, output|
      refute harness.stale_session?(output), harness.name
      %i[session_id result_text usage context model].each { |part| assert_nil harness.public_send(part, output) }
    end
  end

  MANUAL = File.expand_path("../../USER_MANUAL.md", __dir__)

  # The Harnesses table of the user manual has one row per harness file.
  def test_the_user_manual_lists_each_harness
    table = File.read(MANUAL)[/^<!-- harnesses:.*?\n\n/m].to_s
    assert_equal Maf::Shared::Harness.names, table.scan(/^\| `([\w-]+)` \|/).flatten.sort
  end

  def test_the_settings_have_the_expected_shape
    HARNESSES.each do |harness|
      assert_includes %i[watch await poll], harness.wait, harness.name
      assert_equal %i[entry file key], harness.mcp.keys.sort - [:schema], harness.name if harness.mcp
      assert(harness.empty_dirs.all? { |dir| dir.start_with?(".") }, harness.name)
    end
  end
end
