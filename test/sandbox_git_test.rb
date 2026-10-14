#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_git_test.rb - an agent in the sandbox cannot point git at a git
# folder that it wrote. Git on the host would read the config of that folder,
# and a config option (core.fsmonitor) runs a command outside the sandbox.
#
# Run: ruby test/sandbox_git_test.rb
require_relative "sandbox_helper"

class SandboxGitTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  GIT = %w[git -c user.name=t -c user.email=t@t].freeze

  def setup
    skip "no OS sandbox here" unless native_sandbox?
  end

  def test_the_agent_cannot_change_the_links_of_a_worktree
    in_worktree_project do
      sandboxed("echo gitdir: /x > .maf/worktrees/w1/.git; echo /x > .git/worktrees/w1/commondir")
      assert_includes File.read(".maf/worktrees/w1/.git"), "gitdir: #{File.realpath(".git")}"
      assert_equal "../..\n", File.read(".git/worktrees/w1/commondir")
    end
  end

  def test_the_agent_can_commit_in_a_worktree
    in_worktree_project do
      assert sandboxed("cd .maf/worktrees/w1 && touch f && git add f && #{GIT.join(" ")} commit -qm f")
    end
  end

  def test_the_agent_cannot_change_the_worktree_config
    in_worktree_project do
      files = %w[.git/config.worktree .git/worktrees/w1/config.worktree].each { |path| File.write(path, "") }
      sandboxed(files.map { |path| "echo x > #{path}" }.join("; "))
      files.each { |path| assert_empty File.read(path) }
    end
  end

  def test_the_agent_cannot_change_the_git_folder_of_a_submodule
    in_sandboxed_project do
      %w[HEAD config hooks/.keep].each { |name| write(".git/modules/sub/#{name}", "") }
      sandboxed("echo x > .git/modules/sub/config; echo x > .git/modules/sub/hooks/pre-commit")
      assert_equal ["", false], [File.read(".git/modules/sub/config"), File.exist?(".git/modules/sub/hooks/pre-commit")]
    end
  end

  def test_the_agent_cannot_add_a_commondir
    skip "sandbox-exec is macOS only" unless RUBY_PLATFORM.include?("darwin")
    in_sandboxed_project do
      sandboxed("echo /x > .git/commondir")
      refute File.exist?(".git/commondir")
    end
  end

  def in_worktree_project(&block)
    in_sandboxed_project do |dir|
      system(*GIT, "commit", "-q", "--allow-empty", "-m", "init")
      system(*GIT, "worktree", "add", "-q", "-b", "w1", ".maf/worktrees/w1", err: File::NULL)
      block.call(dir)
    end
  end
end
