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
require "yaml"

MAF = File.expand_path("../bin/maf", __dir__)

class MafTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("maf-test"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def maf_at(path, *args)
    output = IO.popen([RbConfig.ruby, path, *args], chdir: @dir, err: [:child, :out], &:read)
    [output, $?.exitstatus]
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

  def test_remove_of_the_last_agent_leaves_an_empty_manifest
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = maf("remove", "opencode:architect", "--no-bootstrap")

    assert_equal 0, status, out
    assert_empty agent_specs
    assert_includes out, "maf add HARNESS:ROLE"
  end

  def test_add_passes_the_hermes_dir_value_through
    skills = File.join(@dir, "skills")

    out, status = maf("add", "--hermes-dir", skills, "hermes:tester", "--no-bootstrap")

    assert_equal 0, status, out
    assert_equal %w[hermes:tester], agent_specs
  end

  def test_a_copied_maf_says_to_link_it
    copy = File.join(@dir, "maf")
    FileUtils.cp(MAF, copy)

    out, status = maf_at(copy, "help")

    refute_equal 0, status
    assert_includes out, "ln -s"
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

  def menu(input)
    output = IO.popen({ "VAULT_SKIP" => "1" }, [RbConfig.ruby, MAF, "menu"], "r+",
                      chdir: @dir, err: [:child, :out]) { |io| io.write(input); io.close_write; io.read }
    [output, $?.exitstatus]
  end

  def role_number(role)
    roles = YAML.load_file(File.expand_path("../templates/roles.yml", __dir__)).fetch("roles").keys
    (roles.index(role) + 1).to_s
  end

  def test_menu_adds_agents
    input = ["1", "1", "#{role_number("architect")},#{role_number("tester")}", "", "", "q"].join("\n")

    out, status = menu("#{input}\n")

    assert_equal 0, status, out
    assert_equal %w[opencode:architect opencode:tester], agent_specs
  end

  def test_menu_removes_an_agent_after_confirmation
    maf("add", "opencode:backend-developer", "opencode:architect", "--no-bootstrap")

    out, status = menu("2\n2\ny\nq\n")

    assert_equal 0, status, out
    assert_equal %w[opencode:backend-developer], agent_specs
  end

  def test_menu_keeps_running_after_an_invalid_choice
    out, status = menu("9\n4\nq\n")

    assert_equal 0, status, out
    assert_includes out, "invalid choice"
    assert_includes out, "architect"
  end

  def test_menu_uninstalls_after_confirmation
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = menu("6
y
q
")

    assert_equal 0, status, out
    refute File.exist?(File.join(@dir, ".agent-flow.json"))
  end

  def test_menu_survives_a_corrupt_manifest
    File.write(File.join(@dir, ".agent-flow.json"), "{")

    out, status = menu("2
q
")

    assert_equal 0, status, out
    assert_includes out, "error:"
    assert_includes out, "q) Quit"
  end

  def test_menu_stops_at_end_of_input
    out, status = menu("")

    assert_equal 0, status, out
  end

  # AgentArgs must know every flow.rb flag that takes a value. Otherwise the
  # value becomes an --agent spec.
  def test_agent_args_value_flags_come_from_the_flow_option_parser
    require File.expand_path("../lib/maf/cli", __dir__)

    assert_equal Flow::Generator.value_flags.sort, Maf::AgentArgs.value_flags.sort
    assert_includes Maf::AgentArgs.value_flags, "--model"
  end

  def test_start_rejects_an_unknown_agent
    maf("add", "opencode:architect", "--no-bootstrap")

    out, status = maf("start", "opencode", "tester")

    refute_equal 0, status
    assert_includes out, "maf add opencode:tester"
  end
end

# maf start execs the harness. A mock opencode program on PATH records its
# directory, arguments, and environment, so the test sees what maf started.
class MafStartTest < Minitest::Test
  MOCK = <<~MOCK
    #!%<ruby>s
    File.write(ENV.fetch("MOCK_LOG"), [Dir.pwd, ENV["COORD_ROLE"], ENV["COORD_WORKER"], *ARGV].join("\\n"))
  MOCK

  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    @dir = File.realpath(Dir.mktmpdir("maf-start-test"))
    @log = File.join(@dir, "mock.log")
    install_mock
    install_project
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def install_mock
    bin = File.join(@dir, "mock-bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "opencode"), format(MOCK, ruby: RbConfig.ruby))
    FileUtils.chmod("+x", File.join(bin, "opencode"))
    @env = { "VAULT_SKIP" => "1", "MOCK_LOG" => @log, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
  end

  def install_project
    @project = File.join(@dir, "project")
    FileUtils.mkdir_p(@project)
    git("init", "-q")
    maf("add", "opencode:architect")
    git("add", "-A")
    git("commit", "-q", "-m", "install")
  end

  def git(*args)
    system("git", "-c", "user.name=test", "-c", "user.email=test@example.com", *args,
           chdir: @project, exception: true, out: File::NULL)
  end

  def maf(*args, input: "")
    output = IO.popen(@env, [RbConfig.ruby, MAF, *args], "r+", chdir: @project, err: [:child, :out]) do |io|
      io.write(input)
      io.close_write
      io.read
    end
    [output, $?.exitstatus]
  end

  def mock_call = File.read(@log).lines(chomp: true)

  def assert_started(worker)
    dir, role, coord_worker, *args = mock_call
    assert_equal File.join(@project, ".worktrees", worker), dir
    assert_equal ["architect", worker], [role, coord_worker]
    assert_equal ["."] + %w[--agent architect --prompt] + ["Start your work loop now."], args
  end

  def test_start_launches_the_harness_in_the_worktree
    out, status = maf("start", "opencode", "architect")

    assert_equal 0, status, out
    assert_started("architect-1")
  end

  def test_start_uses_the_worker_id
    out, status = maf("start", "opencode", "architect_2")

    assert_equal 0, status, out
    assert_started("architect-2")
  end

  def test_menu_starts_the_chosen_agent
    out, status = maf("menu", input: "3\n1\n\nn\n")

    assert_equal 0, status, out
    assert_started("architect-1")
  end
end
