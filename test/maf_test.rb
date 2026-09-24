#!/usr/bin/env ruby
# frozen_string_literal: true

# test/maf_test.rb - tests for the maf command line tool (bin/maf).
#
# Run: ruby test/maf_test.rb
#
# The tests run bin/maf as a subprocess in a disposable project directory.
# maf uses the current directory as the project.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"

MAF = File.expand_path("../bin/maf", __dir__)

class MafTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("maf-test"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def maf(*args)
    output = IO.popen({ "VAULT_SKIP" => "1" }, [RbConfig.ruby, MAF, *args],
                      chdir: @dir, err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end

  def agent_specs
    JSON.parse(File.read(File.join(@dir, ".agent-flow.json")))["agents"].map { |a| "#{a["harness"]}:#{a["role"]}" }
  end

  def role_file(role) = File.join(@dir, ".opencode", "agents", "#{role}.md")

  def test_help_lists_the_commands
    out, status = maf("help")

    assert_equal 0, status, out
    %w[add remove update agents roles start uninstall].each { |command| assert_includes out, command }
  end

  def test_unknown_command_fails
    out, status = maf("nope")

    refute_equal 0, status
    assert_includes out, "unknown command"
  end

  def test_add_takes_agent_specs_as_arguments
    out, status = maf("add", "opencode:backend-developer", "opencode:architect", "--no-bootstrap")

    assert_equal 0, status, out
    assert_equal %w[opencode:backend-developer opencode:architect], agent_specs
    assert File.exist?(role_file("architect"))
    assert_includes out, "maf start opencode architect"
  end

  def test_add_passes_value_flags_through
    out, status = maf("add", "--model", "architect=m1", "opencode:architect", "--no-bootstrap")

    assert_equal 0, status, out
    assert_equal "m1", JSON.parse(File.read(File.join(@dir, ".agent-flow.json")))["agents"].first["model"]
  end

  def test_remove_drops_agents
    maf("add", "opencode:backend-developer", "opencode:architect", "--no-bootstrap")

    out, status = maf("remove", "opencode:architect", "--no-bootstrap")

    assert_equal 0, status, out
    assert_equal %w[opencode:backend-developer], agent_specs
  end

  def test_update_regenerates_the_current_agents
    maf("add", "opencode:architect", "--no-bootstrap")
    File.delete(role_file("architect"))

    out, status = maf("update", "--no-bootstrap")

    assert_equal 0, status, out
    assert File.exist?(role_file("architect"))
  end

  def test_agents_lists_the_current_agents
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = maf("agents")

    assert_equal 0, status, out
    assert_includes out, "opencode:architect"
  end

  def test_agents_without_a_manifest_says_how_to_add_one
    out, status = maf("agents")

    assert_equal 0, status, out
    assert_includes out, "maf add"
  end

  def test_roles_lists_the_roles
    out, status = maf("roles")

    assert_equal 0, status, out
    assert_includes out, "architect"
  end

  def test_uninstall_check_runs_in_the_current_directory
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = maf("uninstall", "--check")

    assert_equal 0, status, out
    assert_includes out, "remove .opencode/agents/architect.md"
  end

  def test_start_rejects_an_unknown_agent
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = maf("start", "opencode", "tester")

    refute_equal 0, status
    assert_includes out, "maf add opencode:tester"
  end
end
