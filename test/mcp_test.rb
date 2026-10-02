#!/usr/bin/env ruby
# frozen_string_literal: true

# test/mcp_test.rb - tests for the graphify MCP server wiring.
#
# Run: ruby test/mcp_test.rb
#
# The tests run bin/maf and assets/vault as subprocesses in a disposable
# project. The worktree test skips when git is absent.
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"

MAF = File.expand_path("../bin/maf", __dir__)
VAULT = File.expand_path("../assets/vault", __dir__)

class McpTestCase < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("maf-mcp-test"))
    @hermes = File.join(@dir, "hermes-skills")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def maf(*args)
    env = { "VAULT_SKIP" => "1", "HOME" => File.join(@dir, "home"), "TASKRC" => nil,
            "COORD_DIR" => nil, "COORD_ROLE" => nil, "COORD_WORKER" => nil }
    out = IO.popen(env, [RbConfig.ruby, MAF, *args], chdir: @dir, err: [:child, :out], &:read)
    [out, $?.exitstatus]
  end

  def add(*specs) = maf("add", *specs, "--no-bootstrap", "--hermes-dir", @hermes)
  def path(*parts) = File.join(@dir, *parts)
  def json(rel) = JSON.parse(File.read(path(rel)))
  def write(rel, text) = File.write(path(rel), text)
end

class McpInstallTest < McpTestCase
  def test_claude_gets_the_server_in_mcp_json
    out, status = add("claude:architect")

    assert_equal 0, status, out
    assert_equal({ "command" => "ruby", "args" => %w[.maf/bin/vault mcp] }, json(".mcp.json").dig("mcpServers", "graphify"))
  end

  def test_opencode_gets_the_server_in_opencode_json
    add("opencode:architect")

    assert_equal({ "type" => "local", "command" => %w[ruby .maf/bin/vault mcp], "enabled" => true },
                 json("opencode.json").dig("mcp", "graphify"))
  end

  def test_codex_and_hermes_get_a_printed_command_and_no_file
    out, = add("codex:architect", "hermes:tester")

    assert_includes out, "codex mcp add graphify-#{File.basename(@dir)} -- ruby #{@dir}/.maf/bin/vault mcp"
    assert_includes out, "hermes mcp add graphify-#{File.basename(@dir)}"
    refute File.exist?(path(".mcp.json"))
  end

  def test_other_servers_and_settings_stay
    write(".mcp.json", JSON.generate("mcpServers" => { "mine" => { "command" => "x" } }, "other" => 1))

    add("claude:architect")

    assert_equal %w[graphify mine], json(".mcp.json").fetch("mcpServers").keys.sort
    assert_equal 1, json(".mcp.json")["other"]
  end

  def test_a_foreign_graphify_entry_stays
    write(".mcp.json", JSON.generate("mcpServers" => { "graphify" => { "command" => "mine" } }))

    out, = add("claude:architect")

    assert_equal "mine", json(".mcp.json").dig("mcpServers", "graphify", "command")
    assert_includes out, "another graphify entry"
  end

  def test_a_broken_file_stays
    write(".mcp.json", "{ not json")

    add("claude:architect")

    assert_equal "{ not json", File.read(path(".mcp.json"))
  end

  def test_a_rerun_changes_nothing
    add("claude:architect")
    before = File.read(path(".mcp.json"))

    out, = add("claude:architect")

    assert_equal before, File.read(path(".mcp.json"))
    refute_includes out, "wrote the graphify server"
  end

  def test_mcp_false_in_the_manifest_turns_the_server_off
    FileUtils.mkdir_p(path(".maf"))
    write(".maf/config.json", JSON.generate("mcp" => false))

    add("claude:architect", "opencode:tester")

    refute File.exist?(path(".mcp.json"))
    refute File.exist?(path("opencode.json"))
    assert_equal false, json(".maf/config.json")["mcp"]
  end
end

class McpUninstallTest < McpTestCase
  def test_uninstall_removes_the_files_that_only_hold_our_entry
    add("claude:architect", "opencode:tester")

    out, status = maf("uninstall", "--yes")

    assert_equal 0, status, out
    refute File.exist?(path(".mcp.json"))
    refute File.exist?(path("opencode.json"))
  end

  def test_uninstall_keeps_other_servers
    write(".mcp.json", JSON.generate("mcpServers" => { "mine" => { "command" => "x" } }))
    add("claude:architect")

    maf("uninstall", "--yes")

    assert_equal({ "mcpServers" => { "mine" => { "command" => "x" } } }, json(".mcp.json"))
  end

  def test_uninstall_keeps_a_foreign_graphify_entry
    write(".mcp.json", JSON.generate("mcpServers" => { "graphify" => { "command" => "mine" } }))
    add("claude:architect")

    maf("uninstall", "--yes")

    assert_equal "mine", json(".mcp.json").dig("mcpServers", "graphify", "command")
  end
end

class VaultMcpTest < McpTestCase
  def setup
    super
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    git("init", "-q")
    git("commit", "-q", "--allow-empty", "-m", "i")
    git("worktree", "add", "-q", "-b", "w", ".maf/worktrees/w")
    FileUtils.mkdir_p(path(".maf", "graphify-out"))
    write(".maf/graphify-out/graph.json", "{}")
    fake_server
  end

  def git(*args) = system("git", "-C", @dir, "-c", "user.email=t@t", "-c", "user.name=t", *args, exception: true)

  def fake_server
    FileUtils.mkdir_p(path("fakebin"))
    write("fakebin/graphify-mcp", "#!/bin/sh\necho \"graph=$1\"\n")
    FileUtils.chmod(0o755, path("fakebin", "graphify-mcp"))
  end

  def test_vault_mcp_in_a_worktree_serves_the_graph_of_the_main_project
    env = { "PATH" => "#{path("fakebin")}:#{ENV["PATH"]}" }
    out = IO.popen(env, [RbConfig.ruby, VAULT, "mcp"], chdir: path(".maf", "worktrees", "w"), err: [:child, :out], &:read)

    assert_equal "graph=#{path(".maf", "graphify-out", "graph.json")}", out.strip
  end
end
