#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_escape_test.rb - an agent in the sandbox cannot weaken the
# sandbox of a later run, and cannot reach a host service. The tests run the
# sandbox of the OS: seatbelt on macOS, bwrap on Linux.
#
# Run: ruby test/sandbox_escape_test.rb
require_relative "sandbox_helper"

class SandboxEscapeTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def setup
    skip "no OS sandbox here" unless native_sandbox?
  end

  def test_the_agent_cannot_change_the_policy
    in_sandboxed_project do
      sandboxed('echo "{\"mode\": \"off\"}" > .maf/sandbox.json')
      assert_equal "auto", JSON.parse(File.read(".maf/sandbox.json"))["mode"]
    end
  end

  def test_the_agent_cannot_move_the_maf_folder_away
    in_sandboxed_project do
      sandboxed("mv .maf .maf-old")
      assert File.exist?(".maf/sandbox.json")
    end
  end

  def test_the_agent_cannot_change_a_git_hook_or_a_flow_script
    in_sandboxed_project do
      sandboxed("echo evil > .git/hooks/post-commit; echo evil > .maf/bin/coord")
      refute File.exist?(".git/hooks/post-commit")
      refute File.exist?(".maf/bin/coord")
    end
  end

  def test_the_agent_cannot_change_the_taskrc
    in_sandboxed_project do
      File.write(".maf/coordination/taskrc", "data.location=x\n")
      sandboxed("echo hooks=on >> .maf/coordination/taskrc")
      assert_equal "data.location=x\n", File.read(".maf/coordination/taskrc")
    end
  end

  def test_the_agent_cannot_add_a_taskwarrior_hook
    in_sandboxed_project do
      hook = ".maf/coordination/taskdata/hooks/on-add-evil"
      sandboxed("mkdir -p #{File.dirname(hook)} && echo evil > #{hook} && chmod +x #{hook}")
      refute File.exist?(hook)
    end
  end

  def test_the_agent_cannot_change_the_flow_config_of_a_harness
    in_sandboxed_project do
      FLOW_CONFIG.each { |file| FileUtils.mkdir_p(File.dirname(file)) && File.write(file, "{}") }
      sandboxed(FLOW_CONFIG.map { |file| "echo evil > #{file}" }.join("; "))
      assert_equal(["{}"] * 2, FLOW_CONFIG.map { |file| File.read(file) })
    end
  end

  FLOW_CONFIG = %w[.maf/claude/settings.json .maf/mcp/claude.json].freeze

  def test_the_agent_cannot_add_a_worktree_hook
    in_sandboxed_project do
      sandboxed("echo evil > .maf/coordination/worktree-env.rb")
      hook = ".maf/coordination/worktree-env.rb"
      refute File.exist?(hook) && File.read(hook).include?("evil")
    end
  end

  def test_the_agent_can_write_the_board_and_the_code
    in_sandboxed_project do
      assert sandboxed("mkdir .maf/coordination/inbox && touch .maf/coordination/inbox/m src.rb")
      assert File.exist?("src.rb")
    end
  end

  def test_the_agent_cannot_reach_a_host_socket_in_tmp
    in_sandboxed_project do
      Dir.mktmpdir("maf-host-", "/tmp") { |dir| refute connects?(File.join(dir, "s")) }
    end
  end
end
