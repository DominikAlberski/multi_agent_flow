#!/usr/bin/env ruby
# frozen_string_literal: true

# test/maf_test.rb - tests for the maf command line tool (bin/maf).
#
# Run: ruby test/maf_test.rb
#
# The tests run bin/maf as a subprocess in a disposable project directory.
# maf uses the current directory as the project.
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require_relative "../lib/maf/team"
require "yaml"

MAF = File.expand_path("../bin/maf", __dir__)

class MafTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("maf-test"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # The agent session that runs the suite exports TASKRC and COORD_DIR for the
  # shared board. Point the child at the disposable board instead.
  def maf_env
    { "VAULT_SKIP" => "1", "HOME" => File.join(@dir, "home"), "TASKRC" => File.join(@dir, ".maf/coordination", "taskrc"),
      "COORD_DIR" => File.join(@dir, ".maf/coordination"), "COORD_ROLE" => nil, "COORD_WORKER" => nil }
  end

  def maf_at(path, *args)
    output = IO.popen(maf_env, [RbConfig.ruby, path, *args], chdir: @dir, err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end

  def maf(*args)
    output = IO.popen(maf_env, [RbConfig.ruby, MAF, *args], chdir: @dir, err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end

  def agent_specs
    JSON.parse(File.read(File.join(@dir, ".maf/config.json")))["agents"].map { |a| "#{a["harness"]}:#{a["role"]}" }
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
    assert_equal "m1", JSON.parse(File.read(File.join(@dir, ".maf/config.json")))["agents"].first["model"]
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
    assert_includes out, "remove .maf/agents/opencode/architect.md"
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
    refute File.exist?(File.join(@dir, ".maf/config.json"))
  end

  def test_menu_survives_a_corrupt_manifest
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
    File.write(File.join(@dir, ".maf/config.json"), "{")

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
module MafProject
  MOCK = <<~MOCK
    #!%<ruby>s
    require "json"
    File.write(ENV.fetch("MOCK_LOG"), [Dir.pwd, ENV["COORD_ROLE"], ENV["COORD_WORKER"], *ARGV].join("\\n"))
    File.write(ENV.fetch("MOCK_LOG") + ".session", JSON.generate(token: ENV["MAF_SESSION_TOKEN"], pid: Process.pid))
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
    @env = @env.merge("TASKRC" => File.join(@project, ".maf/coordination", "taskrc"),
                      "COORD_DIR" => File.join(@project, ".maf/coordination"),
                      "COORD_ROLE" => nil, "COORD_WORKER" => nil)
    git("init", "-q")
    maf("add", "opencode:architect")
    git("add", "-A")
    git("commit", "-q", "--allow-empty", "-m", "install")
  end

  def git(*args)
    system("git", "-c", "user.name=test", "-c", "user.email=test@example.com",
           "-c", "core.hooksPath=#{File::NULL}", *args,
           chdir: @project, exception: true, out: File::NULL)
  end

  def maf(*args, input: "", dir: @project)
    output = IO.popen(@env, [RbConfig.ruby, MAF, *args], "r+", chdir: dir, err: [:child, :out]) do |io|
      io.write(input)
      io.close_write
      io.read
    end
    [output, $?.exitstatus]
  end

  def mock_call = File.read(@log).lines(chomp: true)

  def assert_started(worker)
    dir, role, coord_worker, *args = mock_call
    assert_equal File.join(@project, ".maf/worktrees", worker), dir
    assert_equal ["architect", worker], [role, coord_worker]
    assert_equal ["."] + %w[--agent architect --prompt] + ["Start your work loop now."], args
  end
end

class MafStartTest < Minitest::Test
  include MafProject

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

  def launched_session
    out, status = maf("start", "opencode", "architect")
    assert_equal 0, status, out
    JSON.parse(File.read(@log + ".session"))
  end

  def registration_for(session)
    path = File.join(@project, ".maf/coordination/sessions", "#{session.fetch('token')}.maf.json")
    JSON.parse(File.read(path))
  end

  def test_start_registers_the_harness_process_and_worktree
    session = launched_session
    record = registration_for(session)
    assert_equal session.fetch("pid"), record.fetch("pid")
    assert_equal File.join(@project, ".maf/worktrees/architect-1"), record.fetch("dir")
    assert_equal ["architect", "architect-1"], record.values_at("role", "worker")
  end

  def test_start_replaces_an_old_owned_hook_in_an_existing_worktree
    launched_session
    hook = File.join(@project, ".maf/worktrees/architect-1/.maf/coordination/harness-hooks/next-task.rb")
    File.write(hook, "# next-task.rb - Stop hook for Claude Code and Codex.\nputs 'old global behavior'\n")
    launched_session
    assert_includes File.read(hook), "guard.authorized?"
  end
end

# maf prepare and maf retire let the project manager change the team. The
# user then runs only `cd <worktree>` and `maf start`.
class MafTeamTest < Minitest::Test
  include MafProject

  def worktree(worker) = File.join(@project, ".maf/worktrees", worker)
  def workers = JSON.parse(File.read(File.join(@project, ".maf/coordination", "workers.json")))
  def coord(*args, env: {}) = IO.popen(@env.merge(env), [RbConfig.ruby, ".maf/bin/coord", *args], chdir: @project, &:read)

  # Regression: the suite used to pass an inherited TASKRC/COORD_DIR to coord,
  # so `coord add` wrote a stray task to the agent session's real board. The
  # helper must override both variables.
  def test_coord_does_not_write_to_an_inherited_board
    sentinel = File.join(@dir, "sentinel")
    FileUtils.mkdir_p(File.join(sentinel, ".maf/coordination"))
    File.write(File.join(sentinel, ".maf/coordination", "taskrc"),
               "data.location=#{File.join(sentinel, ".maf/coordination", "taskdata")}\nuda.role.type=string\n")

    with_env("TASKRC" => File.join(sentinel, ".maf/coordination", "taskrc"),
             "COORD_DIR" => File.join(sentinel, ".maf/coordination")) do
      refute_empty coord("add", "--role", "architect", "--scope", "docs/**", "--title", "leak check").strip
    end

    refute Dir.exist?(File.join(sentinel, ".maf/coordination", "taskdata"))
  end

  def with_env(pairs)
    saved = pairs.keys.to_h { |key| [key, ENV[key]] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_prepare_adds_the_role_and_the_worktree
    out, status = maf("prepare", "opencode", "backend-developer_2")

    assert_equal 0, status, out
    assert_includes out, "cd #{worktree("backend-developer-2")}"
    assert File.exist?(File.join(worktree("backend-developer-2"), ".opencode", "agents", "backend-developer.md"))
    assert_equal "opencode", workers.dig("backend-developer-2", "harness")
  end

  # Regression: a project commits its own agents in .claude/agents. A new
  # worktree then had no architect.md, and `claude --agent architect` failed.
  def test_a_worktree_with_own_agent_files_gets_a_link_to_the_role_file
    dir = File.join(@dir, "worktree")
    FileUtils.mkdir_p(File.join(dir, ".claude", "agents"))
    File.write(File.join(dir, ".claude", "agents", "mine.md"), "mine\n")
    FileUtils.mkdir_p(File.join(@project, ".maf", "agents", "claude"))
    File.write(File.join(@project, ".maf", "agents", "claude", "architect.md"), "role\n")

    SetupAgent::RoleFile.copy(@project, dir, "claude", "architect")

    assert_equal "role\n", File.read(File.join(dir, ".claude", "agents", "architect.md"))
    assert_equal "mine\n", File.read(File.join(dir, ".claude", "agents", "mine.md"))
  end

  def test_start_without_arguments_starts_the_prepared_worker
    maf("prepare", "opencode", "architect_2", "--interactive")
    out, status = maf("start", dir: worktree("architect-2"))

    assert_equal 0, status, out
    assert_started("architect-2")
  end

  def test_start_without_arguments_outside_a_worktree_explains_the_usage
    out, status = maf("start")

    refute_equal 0, status
    assert_includes out, "not a prepared worktree"
  end

  def test_start_registers_the_worker
    maf("start", "opencode", "architect")

    assert_equal worktree("architect-1"), workers.dig("architect-1", "dir")
  end

  # The architect never talks to the user, so maf prepare dispatches it.
  def test_prepare_dispatches_the_architect_unless_interactive
    assert_includes Maf::Prepare.mode_args(%w[claude architect]), "--dispatch"
    refute_includes Maf::Prepare.mode_args(%w[claude architect --interactive]), "--dispatch"
    refute_includes Maf::Prepare.mode_args(%w[claude architect --interactive]), "--interactive"
    refute_includes Maf::Prepare.mode_args(%w[claude tester_2]), "--dispatch"
  end

  def test_prepare_with_replace_retires_the_old_worker
    maf("prepare", "opencode", "architect_2", "--interactive")
    out, status = maf("prepare", "opencode", "tester_2", "--replace", "architect_2")

    assert_equal 0, status, out
    refute Dir.exist?(worktree("architect-2"))
    refute workers.key?("architect-2")
    assert workers.key?("tester-2")
  end

  def test_retire_refuses_a_worker_that_still_runs
    maf("prepare", "opencode", "architect_2", "--interactive")
    pid = spawn("sleep", "30", chdir: worktree("architect-2"))
    out, status = maf("retire", "architect_2")

    refute_equal 0, status
    assert_includes out, "still runs"
  ensure
    Process.kill("KILL", pid) if pid
  end

  def test_retire_refuses_uncommitted_work
    maf("prepare", "opencode", "architect_2", "--interactive")
    File.write(File.join(worktree("architect-2"), "work.rb"), "x = 1\n")
    out, status = maf("retire", "architect_2")

    refute_equal 0, status
    assert_includes out, "uncommitted work"
  end

  def manifest = JSON.parse(File.read(File.join(@project, ".maf/config.json")))

  def test_team_set_records_the_budget_and_maf_add_keeps_it
    maf("team", "set", "--max", "2", "--allow", "opencode:deepseek-v4-flash")
    maf("add", "opencode:tester")

    assert_equal({ "max_workers" => 2, "allow" => ["opencode:deepseek-v4-flash"] }, manifest["team"])
  end

  # A corrupt manifest must stop the command with a clear message, not crash
  # with a JSON error and not silently drop the budget.
  def test_team_stops_on_a_corrupt_manifest
    File.write(File.join(@project, ".maf/config.json"), "{ not json")
    out, status = maf("team")

    refute_equal 0, status
    assert_includes out, "not valid JSON"
  end

  # `maf team set` must not overwrite a corrupt manifest with only the team
  # key: that would drop every agent.
  def test_team_set_leaves_a_corrupt_manifest_alone
    File.write(File.join(@project, ".maf/config.json"), "{ not json")
    out, status = maf("team", "set", "--max", "2")

    refute_equal 0, status
    assert_includes out, "not valid JSON"
    assert_equal "{ not json", File.read(File.join(@project, ".maf/config.json"))
  end

  # The budget must not drop the timeouts and the session limits of the roles.
  def test_team_set_keeps_the_timeouts_and_the_limits
    path = File.join(@project, ".maf/config.json")
    team = { "timeouts" => { "reviewer" => 2400 }, "limits" => { "reviewer" => { "max_context" => 80_000 } } }
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("team" => team)))
    maf("team", "set", "--max", "2")

    saved = JSON.parse(File.read(path))["team"]
    assert_equal [2, team["timeouts"], team["limits"]], saved.values_at("max_workers", "timeouts", "limits")
  end

  # The installed post-commit hook starts a detached doc-graph refresh. That
  # process outlives the test and writes into @dir while teardown removes it.
  def test_git_helper_runs_no_hook
    marker = File.join(@dir, "hook-ran")
    hook = File.join(@project, ".git", "hooks", "post-commit")
    File.write(hook, "#!/bin/sh\ntouch \"#{marker}\"\n")
    FileUtils.chmod("+x", hook)
    git("commit", "-q", "--allow-empty", "-m", "probe")

    refute_path_exists marker
  end

  def test_prepare_uses_the_only_allowed_model
    maf("team", "set", "--allow", "opencode:deepseek-v4-flash")
    maf("prepare", "opencode", "tester_1")

    assert_equal "deepseek-v4-flash", workers.dig("tester-1", "model")
  end

  def test_prepare_refuses_a_harness_outside_the_budget
    maf("team", "set", "--allow", "opencode")
    out, status = maf("prepare", "claude", "tester_1")

    refute_equal 0, status
    assert_includes out, "not allowed"
  end

  def test_prepare_refuses_a_worker_over_the_limit
    maf("team", "set", "--max", "1")
    maf("prepare", "opencode", "architect_2", "--interactive")
    out, status = maf("prepare", "opencode", "tester_1")

    refute_equal 0, status
    assert_includes out, "max_workers is 1"
  end

  def test_replace_frees_a_slot_inside_the_limit
    maf("team", "set", "--max", "1")
    maf("prepare", "opencode", "architect_2", "--interactive")
    out, status = maf("prepare", "opencode", "tester_1", "--replace", "architect_2")

    assert_equal 0, status, out
  end

  def test_prepare_with_dispatch_starts_and_retire_stops_the_dispatcher
    out, status = maf("prepare", "opencode", "architect_2", "--dispatch")
    pid = workers.dig("architect-2", "pid")

    assert_equal 0, status, out
    assert Process.kill(0, pid)
    assert_includes maf("team").first, "running (pid #{pid})"
    out, status = maf("retire", "architect_2")
    assert_equal 0, status, out
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  ensure
    Process.kill("KILL", pid) rescue nil if pid
  end

  # Regression: a worktree keeps the dispatcher copy from the day it was made.
  # After maf update, the old copy wrote no worker status for the dashboard.
  def test_dispatch_runs_the_dispatcher_of_the_main_checkout
    maf("prepare", "opencode", "tester_2", "--interactive")
    File.write(File.join(worktree("tester-2"), ".maf", "bin", "dispatcher"), "# stale copy\n")
    out, status = maf("start", "opencode", "tester_2", "--dispatch", "--detach")
    pid = workers.dig("tester-2", "pid")

    assert_equal 0, status, out
    command = IO.popen(["ps", "-o", "command=", "-p", pid.to_s], &:read)
    assert_includes command, File.join(@project, ".maf", "bin", "dispatcher")
  ensure
    Process.kill("KILL", pid) rescue nil if pid
  end

  def test_retire_removes_the_presence_file
    maf("prepare", "opencode", "architect_2", "--interactive")
    path = File.join(@project, ".maf/coordination", "presence", "architect-2.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("worker" => "architect-2", "pid" => Process.pid))
    _out, status = maf("retire", "architect_2")

    assert_equal 0, status
    refute File.exist?(path)
  end

  def test_retire_returns_claimed_tasks_to_the_pool
    skip "Taskwarrior ('task') not installed" unless system("task", "--version", out: File::NULL)
    maf("prepare", "opencode", "architect_2", "--interactive")
    id = coord("add", "--role", "architect", "--scope", "docs/**", "--title", "plan").strip
    coord("claim", id, env: { "COORD_ROLE" => "architect", "COORD_WORKER" => "architect-2" })
    out, status = maf("retire", "architect_2")

    assert_equal 0, status, out
    assert_includes coord("next", "architect"), id
  end
end

module MafArchiveProject
  include MafProject

  WORKER = "architect-2"
  USAGE = JSON.generate("input_tokens" => 12, "output_tokens" => 3, "runs" => 1)

  def setup
    super
    assert_maf("prepare", "opencode", "architect_2", "--interactive")
  end

  def state_path(*parts) = File.join(@project, ".maf", "coordination", *parts)
  def archives = Dir.glob(state_path("archive", "workers", "#{WORKER}-*")).sort

  def write_state(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def seed_state(worker = WORKER, text = "mail")
    write_state(state_path("inbox", worker, "unread.md"), text)
    write_state(state_path("inbox", worker, "read", "old.md"), "#{text} read")
    write_state(state_path("usage", "#{worker}.json"), USAGE)
  end

  def assert_maf(*args)
    output, status = maf(*args)
    assert_equal 0, status, output
  end

  def assert_archived(directory, text = "mail")
    assert_equal text, File.read(File.join(directory, "inbox", "unread.md"))
    assert_equal "#{text} read", File.read(File.join(directory, "inbox", "read", "old.md"))
    assert_equal USAGE, File.read(File.join(directory, "usage.json"))
  end

  def assert_active(worker = WORKER)
    assert_equal "mail", File.read(state_path("inbox", worker, "unread.md"))
    assert_equal USAGE, File.read(state_path("usage", "#{worker}.json"))
  end

  def assert_removed
    refute_path_exists state_path("inbox", WORKER)
    refute_path_exists state_path("usage", "#{WORKER}.json")
  end

  def retire_with_state(text)
    seed_state(WORKER, text)
    assert_maf("retire", "architect_2")
  end
end

class MafRetireArchiveTest < Minitest::Test
  include MafArchiveProject

  def test_retire_archives_unread_mail_read_mail_and_usage
    retire_with_state("mail")
    assert_equal 1, archives.size
    assert_archived(archives.first)
    assert_removed
  end

  def test_retire_preserves_other_worker_and_role_files
    seed_state("tester-2")
    seed_state("architect")
    retire_with_state("mail")
    assert_active("tester-2")
    assert_active("architect")
  end

  # Regression: a new worker with a reused id resumed the retired worker's
  # session and got its handoff note.
  def test_retire_archives_the_session_the_handoff_note_and_the_status
    %w[session handoff.md log].each { |ext| write_state(state_path("sessions", "#{WORKER}.#{ext}"), ext) }
    write_state(state_path("sessions", "architect-20.log"), "other worker")
    write_state(state_path("status", "#{WORKER}.json"), "{}")
    assert_maf("retire", "architect_2")

    assert_equal "handoff.md", File.read(File.join(archives.fetch(0), "sessions", "#{WORKER}.handoff.md"))
    assert_equal "{}", File.read(File.join(archives.first, "status.json"))
    assert_empty Dir.glob(state_path("sessions", "#{WORKER}.*"))
    assert_path_exists state_path("sessions", "architect-20.log")
  end

  def test_retire_archives_usage_without_an_inbox
    write_state(state_path("usage", "#{WORKER}.json"), USAGE)
    assert_maf("retire", "architect_2")
    assert_equal USAGE, File.read(File.join(archives.fetch(0), "usage.json"))
    refute_path_exists File.join(archives.first, "inbox")
    assert_removed
  end

  def test_retire_archives_an_inbox_without_usage
    write_state(state_path("inbox", WORKER, "unread.md"), "mail")
    assert_maf("retire", "architect_2")
    assert_equal "mail", File.read(File.join(archives.fetch(0), "inbox", "unread.md"))
    refute_path_exists File.join(archives.first, "usage.json")
    assert_removed
  end

  def test_retire_without_worker_files_creates_no_archive
    assert_maf("retire", "architect_2")
    refute_path_exists state_path("archive", "workers")
  end

  def test_retire_refuses_dirty_work_without_archiving_files
    seed_state
    File.write(File.join(@project, ".maf", "worktrees", WORKER, "work.rb"), "x = 1\n")
    refute_equal 0, maf("retire", "architect_2").last
    assert_active
    assert_empty archives
  end

  def test_retire_keeps_separate_archives_when_the_worker_id_is_reused
    retire_with_state("first")
    assert_maf("prepare", "opencode", "architect_2", "--interactive")
    retire_with_state("second")
    assert_equal 2, archives.size
    assert_equal %w[first second], archives.map { |dir| File.read(File.join(dir, "inbox", "unread.md")) }.sort
  end

  def test_prepare_with_replacement_archives_the_retired_worker
    seed_state
    assert_maf("prepare", "opencode", "tester_2", "--replace", "architect_2")
    assert_equal 1, archives.size
    assert_archived(archives.first)
    assert_removed
  end

  def test_prepare_with_the_same_worker_id_keeps_active_files
    seed_state
    assert_maf("prepare", "opencode", "architect_2", "--interactive", "--replace", "architect_2")
    assert_active
    assert_empty archives
  end
end
