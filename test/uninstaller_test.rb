#!/usr/bin/env ruby
# frozen_string_literal: true

# test/uninstaller_test.rb - tests for scripts/uninstall.rb.
#
# Run: ruby test/uninstaller_test.rb
#
# Each test installs the flow into a disposable project with flow.rb, then
# runs the uninstaller as a subprocess. Worktree tests skip when git is absent.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
FLOW = File.join(ROOT, "scripts", "flow.rb")
UNINSTALL = File.join(ROOT, "scripts", "uninstall.rb")

class UninstallerTestCase < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("flow-uninstaller-test"))
    @hermes = File.join(@dir, "hermes-skills")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def install
    FileUtils.mkdir_p(File.join(@dir, ".claude"))
    out, status = run_ruby(FLOW, "--project", @dir, "--hermes-dir", @hermes,
                           "--agent", "claude:architect", "--agent", "opencode:tester", "--agent", "hermes:reviewer")
    assert_equal 0, status, out
  end

  def uninstall(*args, stdin: "")
    run_ruby(UNINSTALL, "--project", @dir, *args, stdin: stdin)
  end

  def run_ruby(script, *args, stdin: "")
    out, status = Open3.capture2e({ "VAULT_SKIP" => "1" }, RbConfig.ruby, script, *args, stdin_data: stdin)
    [out, status.exitstatus]
  end

  def path(*parts) = File.join(@dir, *parts)

  def write(rel, content)
    FileUtils.mkdir_p(File.dirname(path(rel)))
    File.write(path(rel), content)
  end
end

class UninstallRemovesTest < UninstallerTestCase
  def test_removes_everything_the_installer_created
    install

    out, status = uninstall("--yes")

    assert_equal 0, status, out
    %w[coord setup_agent dispatcher dashboard vault coordination .agent-flow.json
       AGENTS.md .gitignore .claude .opencode].each { |rel| refute File.exist?(path(rel)), "#{rel} still exists" }
    refute Dir.exist?(File.join(@hermes, "#{File.basename(@dir)}-reviewer"))
  end

  def test_keeps_graphify_and_obsidian_and_their_ignore_rules
    install
    write("graphify-out/graph.json", "{}")
    write("obsidian/note.md", "note")

    uninstall("--yes")

    assert File.exist?(path("graphify-out", "graph.json"))
    assert File.exist?(path("obsidian", "note.md"))
    assert_equal "graphify-out/\nobsidian/\n", File.read(path(".gitignore"))
  end

  def test_keeps_user_text_outside_the_marked_blocks
    write("AGENTS.md", "# My rules\n")
    write(".gitignore", "node_modules/\n")
    install

    uninstall("--yes")

    assert_equal "# My rules\n", File.read(path("AGENTS.md"))
    assert_equal "node_modules/\n", File.read(path(".gitignore"))
  end

  def test_keeps_user_hooks_in_claude_settings
    write(".claude/settings.json", JSON.generate("hooks" => { "Stop" => [user_hook] }, "model" => "x"))
    install

    uninstall("--yes")

    assert_equal({ "hooks" => { "Stop" => [user_hook] }, "model" => "x" },
                 JSON.parse(File.read(path(".claude", "settings.json"))))
  end

  def user_hook
    { "matcher" => "", "hooks" => [{ "type" => "command", "command" => "echo mine" }] }
  end
end

class UninstallKeepsTest < UninstallerTestCase
  def test_keeps_a_foreign_script_and_a_foreign_role_file
    write("coord", "#!/bin/sh\necho mine\n")
    write(".claude/agents/mine.md", "my agent\n")
    install

    uninstall("--yes")

    assert_equal "#!/bin/sh\necho mine\n", File.read(path("coord"))
    assert File.exist?(path(".claude", "agents", "mine.md"))
  end

  def test_check_changes_nothing
    install
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).sort

    out, status = uninstall("--check")

    assert_equal 0, status, out
    assert_includes out, "coordination"
    assert_equal before, Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).sort
  end

  def test_declined_confirmation_changes_nothing
    install

    out, status = uninstall(stdin: "n\n")

    assert_equal 1, status, out
    assert File.exist?(path("coord"))
  end

  def test_confirmation_with_yes_removes
    install

    uninstall(stdin: "yes\n")

    refute File.exist?(path("coord"))
  end

  def test_reports_nothing_to_remove_in_a_clean_project
    out, status = uninstall("--yes")

    assert_equal 0, status, out
    assert_includes out, "nothing to remove"
  end
end

class UninstallWorktreeTest < UninstallerTestCase
  def setup
    super
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    git("init", "-q")
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
    install
    git("worktree", "add", "-q", "-b", "worker/tester-1", ".worktrees/tester-1")
  end

  def git(*args)
    system("git", "-C", @dir, *args, exception: true)
  end

  def test_removes_a_clean_worktree_and_keeps_its_branch
    uninstall("--yes")

    refute Dir.exist?(path(".worktrees"))
    assert system("git", "-C", @dir, "rev-parse", "--verify", "-q", "worker/tester-1", out: File::NULL)
  end

  def test_keeps_a_dirty_worktree_without_force
    write(".worktrees/tester-1/work.txt", "unsaved")

    out, = uninstall("--yes")

    assert File.exist?(path(".worktrees", "tester-1", "work.txt"))
    assert_includes out, "--force"
  end

  def test_force_removes_a_dirty_worktree
    write(".worktrees/tester-1/work.txt", "unsaved")

    uninstall("--yes", "--force")

    refute Dir.exist?(path(".worktrees"))
  end
end
