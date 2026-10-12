#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_test.rb - tests for lib/maf/shared/sandbox.rb.
#
# Run: ruby test/sandbox_test.rb
require_relative "harnesses/helper"
require_relative "../lib/maf/shared/sandbox"

class SandboxTest < Minitest::Test
  include HarnessTestHelpers

  Sandbox = Maf::Shared::Sandbox
  CMD = %w[claude -p go].freeze

  def in_project(config = nil)
    in_tmpdir do |dir|
      system("git", "init", "-q", dir)
      write(".maf/config.json", JSON.generate(config)) if config
      with_env("MAF_SANDBOX" => nil) { yield dir }
    end
  end

  def test_the_sandbox_is_off_by_default
    in_project { assert_equal CMD, Sandbox.wrap(CMD, harness("claude")) }
  end

  def test_the_config_turns_the_sandbox_on
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      cmd = Sandbox.wrap(CMD, harness("claude"))
      assert_equal ["sandbox-exec", "-p"], cmd.first(2)
      assert_equal CMD, cmd.drop(3)
    end
  end

  def test_the_environment_overrides_the_config
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      with_env("MAF_SANDBOX" => "off") { assert_equal CMD, Sandbox.wrap(CMD, harness("claude")) }
    end
  end

  def test_an_unknown_mode_stops_maf
    in_project("sandbox" => { "mode" => "docker" }) do
      assert_raises(SystemExit) { capture_io { Sandbox.wrap(CMD, harness("claude")) } }
    end
  end

  def test_the_profile_allows_the_project_the_board_the_harness_and_the_config_paths
    in_project("sandbox" => { "mode" => "seatbelt", "write" => ["/opt/extra"] }) do |dir|
      profile = Sandbox.wrap(CMD, harness("codex"), coord_dir: "/srv/board")[2]
      paths = [dir, "/srv/board", "/opt/extra", File.realpath("/tmp"), harness("codex").home]
      paths.each { |path| assert_includes profile, "(subpath \"#{path}\")" }
    end
  end

  def test_the_profile_denies_each_other_write
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      assert_includes Sandbox.wrap(CMD, harness("claude"))[2], "(deny file-write*)"
    end
  end

  def test_claude_may_write_its_state_file
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      assert_includes Sandbox.wrap(CMD, harness("claude"))[2], "(prefix \"#{Dir.home}/.claude.json\")"
    end
  end

  def test_quotes_and_backslashes_in_a_path_are_escaped
    assert_equal '"/a\\"b\\\\c"', Sandbox::Seatbelt.quote('/a"b\\c')
  end

  # Codex runs its own sandbox-exec. It fails inside a sandbox, so maf turns it off.
  def test_an_interactive_codex_session_turns_off_its_own_sandbox
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      cmd = Sandbox.wrap(%w[codex --add-dir x prompt], harness("codex"))
      assert_equal %w[codex --sandbox danger-full-access --add-dir x prompt], cmd.drop(3)
    end
  end

  def test_a_dispatched_codex_run_keeps_its_flags
    run = %w[codex exec --dangerously-bypass-approvals-and-sandbox go]
    assert_equal run, harness("codex").sandboxed(run)
  end

  def touch_sandboxed(path) = system(*Sandbox.wrap(["touch", path], harness("claude")), err: File::NULL)

  def test_the_sandbox_blocks_a_write_outside_the_project
    skip "sandbox-exec is macOS only" unless Sandbox::Seatbelt.available?
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      assert touch_sandboxed(File.join(dir, "in"))
      Dir.mktmpdir(nil, Dir.home) { |outside| refute touch_sandboxed(File.join(outside, "out")) }
    end
  end
end
