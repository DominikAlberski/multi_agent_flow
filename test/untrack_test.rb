#!/usr/bin/env ruby
# frozen_string_literal: true

# test/untrack_test.rb - tests for maf untrack.
#
# Run: ruby test/untrack_test.rb
#
# The test builds an install that git tracks, as an older maf made it, then
# runs bin/maf untrack as a subprocess.
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require_relative "../lib/maf/local_exclude"

class UntrackTest < Minitest::Test
  MAF = File.expand_path("../bin/maf", __dir__)
  HOOK = "ruby .maf/coordination/harness-hooks/next-task.rb"
  BLOCK = "# >>> multi-agent-flow >>>\nold rule\n# <<< multi-agent-flow <<<\n"

  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    @dir = File.realpath(Dir.mktmpdir("maf-untrack-test"))
    install_like_an_old_maf
  end

  def install_like_an_old_maf
    git("init", "-q")
    maf("add", "claude:architect")
    write(".gitignore", "node_modules/\n#{BLOCK}")
    track_like_an_old_install
    git("commit", "-q", "-m", "old install")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def maf(*args)
    env = { "VAULT_SKIP" => "1", "HOME" => File.join(@dir, "home"), "TASKRC" => nil,
            "COORD_DIR" => nil, "COORD_ROLE" => nil, "COORD_WORKER" => nil }
    out = IO.popen(env, [RbConfig.ruby, MAF, *args], chdir: @dir, err: %i[child out], &:read)
    [out, $?.exitstatus]
  end

  # No git hooks: the doc-graph refresh would run in the background and race the teardown.
  def git(*args) = system("git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                          "-c", "core.hooksPath=#{File::NULL}", *args, chdir: @dir, exception: true, out: File::NULL)

  def write(rel, text) = File.write(File.join(@dir, rel), text)
  def read(rel) = File.read(File.join(@dir, rel))
  def tracked = IO.popen(["git", "-C", @dir, "ls-files"], &:readlines).map(&:chomp)

  MINE = { "PreToolUse" => [{ "hooks" => [{ "command" => "mine" }] }] }.freeze
  GRAPHIFY = { "command" => "ruby", "args" => %w[.maf/bin/vault mcp] }.freeze

  def track_like_an_old_install
    write("AGENTS.md", "# Mine\n\n<!-- >>> multi-agent-flow >>> -->\ncontract\n<!-- <<< multi-agent-flow <<< -->\n")
    ours = { "Stop" => [{ "hooks" => [{ "command" => HOOK }] }] }
    write(".claude/settings.json", JSON.generate("hooks" => MINE.merge(ours)))
    write(".mcp.json", JSON.generate("mcpServers" => { "graphify" => GRAPHIFY, "mine" => { "command" => "x" } }))
    git("add", "-f", "-A")
  end

  def test_untrack_removes_the_flow_from_git_and_keeps_the_files
    out, status = maf("untrack", "--yes")

    assert_equal 0, status, out
    assert_empty tracked.grep(%r{\A\.maf/|\A\.claude/agents})
    assert File.exist?(File.join(@dir, ".maf", "bin", "coord"))
    assert_includes LocalExclude.listed(File.join(@dir, ".git", "info", "exclude")), ".maf/"
  end

  def test_untrack_keeps_the_project_text_and_drops_the_flow_text
    maf("untrack", "--yes")

    assert_equal "# Mine\n", read("AGENTS.md")
    assert_equal "node_modules/\n", read(".gitignore")
    assert_equal MINE, JSON.parse(read(".claude/settings.json"))["hooks"]
    assert_equal %w[mine], JSON.parse(read(".mcp.json"))["mcpServers"].keys
  end

  def test_untrack_rebuilds_the_local_files_of_the_flow
    maf("untrack", "--yes")

    assert File.exist?(File.join(@dir, ".maf", "claude", "settings.json"))
    assert File.exist?(File.join(@dir, ".maf", "mcp", "claude.json"))
  end

  def test_check_changes_nothing
    out, = maf("untrack", "--check")

    assert_includes out, "git rm --cached"
    assert_includes tracked, ".maf/config.json"
  end

  def test_a_second_run_finds_nothing
    maf("untrack", "--yes")
    git("commit", "-q", "-m", "untrack")

    out, = maf("untrack", "--check")

    assert_includes out, "git tracks no file of the flow"
  end
end
