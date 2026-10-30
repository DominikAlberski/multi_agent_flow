#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_test.rb - tests for lib/maf/shared/sandbox.rb.
#
# Run: ruby test/sandbox_test.rb
require_relative "sandbox_helper"

class SandboxTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def test_the_sandbox_is_off_by_default
    in_project { assert_equal CMD, Sandbox.wrap(CMD, harness("claude")) }
  end

  def test_the_config_turns_the_sandbox_on
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      cmd = Sandbox.wrap(CMD, harness("claude"))
      assert_equal ["/usr/bin/sandbox-exec", "-p", "env"], cmd.values_at(0, 1, 3)
      assert_equal CMD, cmd.drop(8)
    end
  end

  def test_the_environment_overrides_the_config
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      with_env("MAF_SANDBOX" => "off") { assert_equal CMD, Sandbox.wrap(CMD, harness("claude")) }
    end
  end

  def test_a_bad_policy_stops_maf
    ['{"mode": "docker"}', '{"mode": "auto",}', "[]"].each { |text| assert_raises(SystemExit) { wrap_with(text) } }
  end

  def wrap_with(policy)
    in_project { write(".maf/sandbox.json", policy) && capture_io { Sandbox.wrap(CMD, harness("claude")) } }
  end

  def test_seatbelt_without_sandbox_exec_stops_maf
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      with_seatbelt(false) { assert_raises(SystemExit) { capture_io { Sandbox.mode } } }
    end
  end

  def test_the_profile_allows_the_project_the_board_the_harness_and_the_config_paths
    in_project("sandbox" => { "mode" => "seatbelt", "write" => ["/opt/extra"] }) do |dir|
      profile = Sandbox.wrap(CMD, harness("codex"), coord_dir: "/srv/board")[2]
      paths = [dir, "/srv/board", "/opt/extra", File.realpath("/tmp")]
      paths.each { |path| assert_includes profile, "(subpath \"#{path}\")" }
    end
  end

  def test_the_profile_denies_each_other_write
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      assert_includes Sandbox.wrap(CMD, harness("claude"))[2], "(deny file-write*)"
    end
  end

  def test_the_profile_allows_only_the_sockets_in_the_allowed_folders
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      profile = Sandbox.wrap(CMD, harness("claude"))[2]
      assert_includes profile, "(deny network-outbound (remote unix-socket))"
      assert_includes profile, "(allow network-outbound (remote unix-socket (subpath \"#{dir}\")))"
    end
  end

  def test_the_sandbox_opens_the_folders_of_each_harness_of_the_project
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      write(".maf/config.json", JSON.generate("agents" => [{ "harness" => "codex", "role" => "tester" }]))
      assert_includes Sandbox.wrap(CMD, harness("claude"))[2], state_rule(harness("codex").home, "sessions")
    end
  end

  def test_the_policy_file_exists_after_the_first_run
    in_project do
      FileUtils.mkdir_p(".maf")
      with_env("MAF_SANDBOX" => "seatbelt") { Sandbox.wrap(CMD, harness("claude")) }
      assert_equal({}, JSON.parse(File.read(".maf/sandbox.json")))
    end
  end

  def test_claude_may_write_its_state_file
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      assert_includes Sandbox.wrap(CMD, harness("claude"))[2], "(prefix \"#{Dir.home}/.claude.json\")"
    end
  end

  def test_the_profile_protects_the_config_of_each_harness
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      denials = with_env("CODEX_HOME" => "#{dir}/codex") { denials(harness("codex")) }
      %w[config.toml packages AGENTS.override.md].each { |name| assert_includes denials, subpath(dir, "codex/#{name}") }
    end
  end

  def denials(harness) = Sandbox.wrap(CMD, harness)[2].split("(deny file-write*\n").last
  def subpath(dir, path) = "(subpath \"#{dir}/#{path}\")"

  def test_the_profile_protects_a_symlink_and_its_target
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      link_taskrc(dir)
      denials = Sandbox.wrap(CMD, harness("claude"))[2]
      ["dotfiles/taskrc", TASKRC].each { |path| assert_includes denials, "(subpath \"#{dir}/#{path}\")" }
    end
  end

  TASKRC = ".maf/coordination/taskrc"

  def link_taskrc(dir)
    write("dotfiles/taskrc", "")
    FileUtils.mkdir_p(".maf/coordination")
    File.symlink("#{dir}/dotfiles/taskrc", TASKRC)
  end

  def test_quotes_and_backslashes_in_a_path_are_escaped
    assert_equal '"/a\\"b\\\\c"', Sandbox::Seatbelt.quote('/a"b\\c')
  end

  def test_an_interactive_codex_session_turns_off_its_own_sandbox
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      cmd = Sandbox.wrap(%w[codex --add-dir x prompt], harness("codex"))
      assert_equal %w[codex --sandbox danger-full-access --add-dir x prompt], cmd.drop(8)
    end
  end

  def test_a_dispatched_codex_run_keeps_its_flags
    run = %w[codex exec --dangerously-bypass-approvals-and-sandbox go]
    assert_equal run, harness("codex").sandboxed(run)
  end
end
