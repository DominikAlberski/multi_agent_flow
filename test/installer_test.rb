#!/usr/bin/env ruby
# frozen_string_literal: true

# test/installer_test.rb - tests for the installer layer:
# lib/maf/bootstrap.rb, lib/maf/flow.rb, and lib/maf/setup_agent.rb.
#
# Run: ruby test/installer_test.rb
#
# The tests run bootstrap.rb and the flow.rb generator as subprocesses
# against a disposable project directory. setup_agent.rb is loaded directly
# so its parsing can be unit tested. No external tools (task, git, graphify)
# are required.
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
LIB = File.join(ROOT, "lib", "maf")
BOOTSTRAP = File.join(LIB, "bootstrap.rb")
FLOW = ["-r", File.join(LIB, "flow.rb"), "-e", "Flow::Generator.new(ARGV).run", "--"].freeze
require File.join(LIB, "setup_agent")
require File.join(LIB, "flow")
load File.join(ROOT, "assets", "vault")

class InstallerTestCase < Minitest::Test
  def setup
    # realpath: bootstrap resolves its target with File.realpath, and on macOS
    # /var is a symlink to /private/var.
    @dir = File.realpath(Dir.mktmpdir("flow-installer-test"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_ruby(script, *args)
    # VAULT_SKIP: bootstrap's vault auto-start spawns a detached daemon. In a
    # test that daemon would outlive the disposable dir, so keep it off.
    output = IO.popen({ "VAULT_SKIP" => "1", "HOME" => File.join(@dir, "home") }, [RbConfig.ruby, script, *args],
                      err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end
end

class BootstrapTest < InstallerTestCase
  def bootstrap(*args)
    run_ruby(BOOTSTRAP, @dir, "--roles", "architect,backend-developer", *args)
  end

  def taskrc_path = File.join(@dir, ".maf/coordination", "taskrc")

  def test_installs_coordination_layer
    out, status = bootstrap

    assert_equal 0, status, out
    assert File.executable?(File.join(@dir, ".maf", "bin", "coord"))
    refute File.exist?(File.join(@dir, "setup_agent"))
    assert_includes File.read(taskrc_path), "data.location=#{File.join(@dir, ".maf/coordination", "taskdata")}"
    assert_includes File.read(File.join(@dir, "AGENTS.md")), ">>> multi-agent-flow >>>"
    assert_includes File.read(File.join(@dir, ".gitignore")), ".maf/env.sh"
  end

  # Root keeps only .maf/ and AGENTS.md (and .gitignore, which git reads there).
  def test_installs_only_the_flow_folder_and_the_text_files_at_the_root
    out, status = bootstrap

    assert_equal 0, status, out
    assert_equal %w[.gitignore .maf AGENTS.md], Dir.children(@dir).sort
    assert_equal %w[bin coordination env.sh], Dir.children(File.join(@dir, ".maf")).sort
  end

  def test_ignore_rules_cover_the_runtime_folders
    bootstrap

    rules = File.read(File.join(@dir, ".gitignore")).lines.map(&:strip)

    %w[.maf/coordination/ .maf/worktrees/ .maf/graphify-out/ .maf/obsidian/ .maf/*.log .maf/*.pid].each do |rule|
      assert_includes rules, rule
    end
  end

  def test_env_sh_puts_the_flow_bin_folder_on_the_path
    bootstrap

    out, status = Open3.capture2e("bash", "-c", "source .maf/env.sh && command -v coord && echo $MAF_BIN", chdir: @dir)

    assert_equal 0, status.exitstatus, out
    assert_equal [File.join(@dir, ".maf", "bin", "coord"), File.join(@dir, ".maf", "bin")], out.lines.map(&:strip)
  end

  def test_is_idempotent
    bootstrap
    taskrc = File.read(taskrc_path)
    contract = File.read(File.join(@dir, "AGENTS.md"))

    out, status = bootstrap

    assert_equal 0, status, out
    assert_equal taskrc, File.read(taskrc_path)
    assert_equal contract, File.read(File.join(@dir, "AGENTS.md"))
    assert_equal 1, contract.scan(">>> multi-agent-flow >>>").size
  end

  # Regression: a re-run skipped any file that already had the marker, so an
  # existing install never got new ignore rules (e.g. `obsidian/` after the
  # vault/ rename) or new contract commands. The stale block must be replaced
  # in place, and text outside the block must survive.
  def test_rerun_replaces_a_stale_marked_block
    gitignore = File.join(@dir, ".gitignore")
    File.write(gitignore, "node_modules/\n\n# >>> multi-agent-flow >>>\nvault/\n# <<< multi-agent-flow <<<\nafter/\n")

    out, status = bootstrap

    assert_equal 0, status, out
    content = File.read(gitignore)
    assert_includes content, "obsidian/"
    refute_match(/^vault\/$/, content)
    assert content.start_with?("node_modules/\n")
    assert content.end_with?("after/\n")
    assert_equal 1, content.scan(">>> multi-agent-flow >>>").size
  end

  def test_check_does_not_replace_a_stale_block
    gitignore = File.join(@dir, ".gitignore")
    stale = "# >>> multi-agent-flow >>>\nvault/\n# <<< multi-agent-flow <<<\n"
    File.write(gitignore, stale)

    out, = bootstrap("--check")

    assert_includes out, "replace"
    assert_equal stale, File.read(gitignore)
  end

  def test_refuses_a_foreign_coord_script
    FileUtils.mkdir_p(File.join(@dir, ".maf", "bin"))
    File.write(File.join(@dir, ".maf", "bin", "coord"), "# someone else's tool\n")

    out, status = bootstrap

    assert_equal 0, status, out
    assert_includes out, "REFUSE"
    assert_equal "# someone else's tool\n", File.read(File.join(@dir, ".maf", "bin", "coord"))
  end

  # Regression: a pre-existing, non-flow .maf/coordination/taskrc must never be
  # overwritten. It may point at a real Taskwarrior database.
  def test_refuses_a_foreign_taskrc
    FileUtils.mkdir_p(File.dirname(taskrc_path))
    File.write(taskrc_path, "data.location=/home/me/.task\n")

    out, status = bootstrap

    assert_equal 0, status, out
    assert_includes out, "REFUSE"
    assert_equal "data.location=/home/me/.task\n", File.read(taskrc_path)
  end

  def test_force_overwrites_a_foreign_taskrc
    FileUtils.mkdir_p(File.dirname(taskrc_path))
    File.write(taskrc_path, "data.location=/home/me/.task\n")

    out, status = bootstrap("--force")

    assert_equal 0, status, out
    content = File.read(taskrc_path)
    refute_includes content, "/home/me/.task"
    assert_includes content, "data.location="
  end

  # Regression: a marked taskrc from an older install that has no
  # data.location would silently fall back to the global ~/.task database.
  def test_upgrades_a_marked_taskrc_missing_data_location
    FileUtils.mkdir_p(File.dirname(taskrc_path))
    File.write(taskrc_path, "# >>> multi-agent-flow >>>\nuda.role.type=string\n")

    out, status = bootstrap

    assert_equal 0, status, out
    content = File.read(taskrc_path)
    assert_includes content, "data.location=#{File.join(@dir, ".maf/coordination", "taskdata")}"
    assert_includes content, "uda.role.type=string"
  end

  def test_check_writes_nothing
    out, status = bootstrap("--check")

    assert_equal 0, status, out
    assert_includes out, "--check: no changes made."
    refute File.exist?(File.join(@dir, ".maf"))
    refute File.exist?(taskrc_path)
  end

  # Regression: vault auto-start spawns a detached daemon. VAULT_SKIP must stop
  # it, so bootstrap in tests/CI never leaves an orphan process behind.
  def test_vault_skip_prevents_auto_start
    out, status = bootstrap

    assert_equal 0, status, out
    assert_includes out, "skipped (VAULT_SKIP is set)"
    refute File.exist?(File.join(@dir, ".maf/coordination", "vault.pid"))
  end

  def test_adds_board_watch_hooks_to_claude_settings_once
    settings_path = File.join(@dir, ".claude", "settings.json")
    FileUtils.mkdir_p(File.dirname(settings_path))
    File.write(settings_path, JSON.generate(hooks: { Stop: [{ matcher: "", hooks: [{ type: "command",
                                                     command: "ruby .maf/coordination/harness-hooks/next-task.rb" }] }] }))
    2.times { assert_equal 0, bootstrap.last }

    hooks = JSON.parse(File.read(settings_path))["hooks"]
    watch = hooks["SessionStart"].map { |entry| entry["hooks"][0] }
    async = watch.select { |hook| hook["asyncRewake"] }
    assert_equal [true], async.map { |hook| hook["asyncRewake"] }
    assert_equal ["ruby .maf/coordination/harness-hooks/board-watch.rb"], async.map { |hook| hook["command"] }
    assert_equal 2, hooks["Stop"].size
    assert File.exist?(File.join(@dir, ".maf/coordination", "harness-hooks", "board-watch.rb"))
    assert Dir.exist?(File.join(@dir, ".maf/coordination", "message-hooks"))
  end

  def opencode_plugin = File.join(@dir, ".opencode", "plugins", "board-watch.js")

  def test_installs_the_opencode_plugin_when_opencode_is_used
    FileUtils.mkdir_p(File.join(@dir, ".opencode"))
    2.times { assert_equal 0, bootstrap.last }

    assert_includes File.read(opencode_plugin), "board-watch-opencode.js - opencode plugin"
  end

  def test_skips_the_opencode_plugin_without_opencode
    assert_equal 0, bootstrap.last

    refute File.exist?(opencode_plugin)
  end

  # Claude Code reads AGENTS.md only when no project CLAUDE.md exists, so the
  # user's CLAUDE.md text moves into AGENTS.md and CLAUDE.md goes.
  def test_moves_claude_md_into_agents_md
    File.write(File.join(@dir, "AGENTS.md"), "# Agents rules\n")
    File.write(File.join(@dir, "CLAUDE.md"), "# Claude rules\n@AGENTS.md\n")

    out, status = bootstrap

    assert_equal 0, status, out
    refute File.exist?(File.join(@dir, "CLAUDE.md"))
    agents = File.read(File.join(@dir, "AGENTS.md"))
    assert agents.start_with?("# Agents rules\n\n# Claude rules\n")
    refute_includes agents, "@AGENTS.md"
    assert_equal 1, agents.scan(">>> multi-agent-flow >>>").size
  end

  def test_moves_dot_claude_claude_md_and_drops_its_old_contract
    path = File.join(@dir, ".claude", "CLAUDE.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# Mine\n\n<!-- >>> multi-agent-flow >>> -->\nold\n<!-- <<< multi-agent-flow <<< -->\n")

    out, status = bootstrap

    assert_equal 0, status, out
    refute File.exist?(path)
    agents = File.read(File.join(@dir, "AGENTS.md"))
    assert agents.start_with?("# Mine\n")
    refute_match(/^old$/, agents)
    assert_equal 1, agents.scan(">>> multi-agent-flow >>>").size
  end

  def test_check_does_not_move_claude_md
    File.write(File.join(@dir, "CLAUDE.md"), "# Claude rules\n")

    out, = bootstrap("--check")

    assert_includes out, "CLAUDE.md (move into AGENTS.md)"
    assert_equal "# Claude rules\n", File.read(File.join(@dir, "CLAUDE.md"))
  end
end

class FlowTest < InstallerTestCase
  def flow(*args)
    run_ruby(*FLOW, "--project", @dir, "--no-bootstrap", *args)
  end

  def agent_file = File.join(@dir, ".opencode", "agents", "backend-developer.md")
  def architect_file = File.join(@dir, ".opencode", "agents", "architect.md")
  def manifest = JSON.parse(File.read(File.join(@dir, ".maf/config.json")))

  def test_generates_agent_file_and_manifest
    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    assert File.exist?(agent_file)
    assert_equal [{ "harness" => "opencode", "role" => "backend-developer", "model" => nil, "can_edit" => true }],
                 manifest["agents"]
  end

  def agent_specs = manifest["agents"].map { |a| "#{a["harness"]}:#{a["role"]}" }

  def test_rerun_adds_an_agent_and_keeps_the_current_agents
    flow("--agent", "opencode:backend-developer")

    out, status = flow("--agent", "opencode:architect")

    assert_equal 0, status, out
    assert_equal %w[opencode:backend-developer opencode:architect], agent_specs
    assert File.exist?(architect_file)
  end

  def test_rerun_without_agents_regenerates_the_current_agents
    flow("--agent", "opencode:backend-developer")
    File.delete(agent_file)

    out, status = flow

    assert_equal 0, status, out
    assert File.exist?(agent_file)
  end

  def test_remove_drops_an_agent_from_the_manifest
    flow("--agent", "opencode:backend-developer", "--agent", "opencode:architect")

    out, status = flow("--remove", "opencode:architect")

    assert_equal 0, status, out
    assert_equal %w[opencode:backend-developer], agent_specs
  end

  def test_rerun_keeps_a_saved_model_unless_model_overrides_it
    flow("--agent", "opencode:backend-developer:m1")
    flow("--agent", "opencode:architect", "--agent", "opencode:backend-developer")
    assert_equal "m1", manifest["agents"].first["model"]

    flow("--model", "backend-developer=m2")
    assert_equal "m2", manifest["agents"].first["model"]
  end

  def test_is_idempotent
    flow("--agent", "opencode:backend-developer")
    first = File.read(agent_file)

    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    assert_includes out, "skip"
    assert_equal first, File.read(agent_file)
  end

  def stored_agent_file = File.join(@dir, ".maf", "agents", "opencode", "backend-developer.md")

  def test_refuses_a_foreign_agent_file
    FileUtils.mkdir_p(File.dirname(stored_agent_file))
    File.write(stored_agent_file, "# hand-written agent\n")

    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    assert_includes out, "refuse"
    assert_equal "# hand-written agent\n", File.read(stored_agent_file)
  end

  # The harness folder is a committed relative symlink into .maf/agents/.
  def test_the_harness_folder_is_a_symlink_into_the_flow_folder
    flow("--agent", "opencode:backend-developer", "--agent", "codex:architect")

    assert File.symlink?(File.join(@dir, ".opencode", "agents"))
    assert_equal "../.maf/agents/opencode", File.readlink(File.join(@dir, ".opencode", "agents"))
    assert_equal "../.maf/agents/codex", File.readlink(File.join(@dir, ".codex", "prompts"))
    assert File.exist?(stored_agent_file)
  end

  # Regression: TastingCompanion keeps its own agents in .claude/agents. The
  # harness then found no role file, and the startup prompt named a missing file.
  def test_a_harness_folder_with_foreign_files_gets_a_link_for_each_role_file
    FileUtils.mkdir_p(File.join(@dir, ".opencode", "agents"))
    File.write(File.join(@dir, ".opencode", "agents", "mine.md"), "mine\n")

    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    link = File.join(@dir, ".opencode", "agents", "backend-developer.md")
    assert_equal "../../.maf/agents/opencode/backend-developer.md", File.readlink(link)
    assert_equal File.read(stored_agent_file), File.read(link)
    assert_equal "mine\n", File.read(File.join(@dir, ".opencode", "agents", "mine.md"))
  end

  def test_an_own_file_with_the_role_name_stays_and_the_run_warns
    FileUtils.mkdir_p(File.join(@dir, ".opencode", "agents"))
    File.write(File.join(@dir, ".opencode", "agents", "backend-developer.md"), "mine\n")

    out, = flow("--agent", "opencode:backend-developer")

    assert_includes out, "own files named backend-developer.md"
    assert_equal "mine\n", File.read(File.join(@dir, ".opencode", "agents", "backend-developer.md"))
  end

  def test_the_link_of_a_removed_role_is_pruned
    FileUtils.mkdir_p(File.join(@dir, ".opencode", "agents"))
    File.write(File.join(@dir, ".opencode", "agents", "mine.md"), "mine\n")
    File.symlink("../../.maf/agents/opencode/gone.md", File.join(@dir, ".opencode", "agents", "gone.md"))

    flow("--agent", "opencode:backend-developer")

    refute File.symlink?(File.join(@dir, ".opencode", "agents", "gone.md"))
  end

  def test_the_symlink_is_not_rewritten_on_a_rerun
    flow("--agent", "opencode:backend-developer")
    before = File.lstat(File.join(@dir, ".opencode", "agents")).ino

    flow("--agent", "opencode:backend-developer")

    assert_equal before, File.lstat(File.join(@dir, ".opencode", "agents")).ino
  end

  # Regression: the manifest must not embed the absolute default hermes skills
  # path. It is a home-directory path that would leak into a committed file.
  def test_manifest_omits_the_default_hermes_dir
    flow("--agent", "opencode:backend-developer")

    refute manifest.key?("hermes_dir")
  end

  def test_manifest_records_a_custom_hermes_dir
    custom = File.join(@dir, "custom-hermes")
    out, status = flow("--agent", "hermes:reviewer", "--hermes-dir", custom)

    assert_equal 0, status, out
    assert_equal custom, manifest["hermes_dir"]
  end

  def test_architect_prompt_adds_tasks_with_the_role_flag
    out, status = flow("--agent", "opencode:architect")

    assert_equal 0, status, out
    content = File.read(architect_file)
    assert_includes content, "coord add --role <role>"
    refute_match(/COORD_AGENT|coord add --agent/, content)
  end

  # The dispatcher adds the report block rule to each dispatched prompt.
  # The role files do not repeat it: each model call would send it again.
  def test_role_files_leave_the_report_block_to_the_dispatcher
    out, status = flow("--agent", "claude:backend-developer", "--agent", "opencode:architect")

    assert_equal 0, status, out
    [File.join(@dir, ".claude", "agents", "backend-developer.md"), architect_file].each do |path|
      refute_includes File.read(path), "<report>"
    end
  end

  def test_bootstrap_contract_uses_the_new_names
    contract = File.read(File.join(ROOT, "assets", "agents-contract.md"))

    refute_match(/COORD_AGENT|--agent ROLE|coordination\/hooks\//, contract)
    assert_includes contract, "COORD_ROLE"
  end

  # Regression: the architect prompt used to tell the architect to take goals
  # only from the project manager even when no project-manager role was set up,
  # so it pointed at an inbox nobody runs and refused the user's request.
  def test_architect_prompt_points_to_the_project_manager_when_pm_is_present
    out, status = flow("--agent", "opencode:architect", "--agent", "opencode:project-manager")

    assert_equal 0, status, out
    content = File.read(architect_file)
    assert_includes content, "Read goals from the project manager"
    assert_includes content, "coord msg --from architect project-manager"
    refute_includes content, "no project manager"
  end

  def test_architect_prompt_takes_user_requests_when_no_pm_is_present
    out, status = flow("--agent", "opencode:architect", "--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    content = File.read(architect_file)
    assert_includes content, "Read the user's request"
    assert_includes content, "no project manager"
    refute_includes content, "coord msg --from architect project-manager"
  end

  # Regression: bootstrap ran before flow wrote .claude/agents/. Bootstrap saw
  # no .claude/ directory and skipped the Claude hooks, so idle Claude agents
  # had no board watcher and never woke up.
  def test_claude_agent_gets_board_watch_hooks_on_a_fresh_project
    out, status = run_ruby(*FLOW, "--project", @dir, "--agent", "claude:backend-developer")

    assert_equal 0, status, out
    settings = JSON.parse(File.read(File.join(@dir, ".claude", "settings.json")))
    commands = settings["hooks"]["SessionStart"].map { |entry| entry["hooks"][0]["command"] }
    assert_includes commands, "ruby .maf/coordination/harness-hooks/board-watch.rb"
  end

  def test_claude_worker_stops_and_the_board_watcher_wakes_it
    out, status = flow("--agent", "claude:backend-developer")

    assert_equal 0, status, out
    content = File.read(File.join(@dir, ".claude", "agents", "backend-developer.md"))
    assert_includes content, "The board watcher wakes you"
    refute_includes content, "coord next --wait"
  end

  # The opencode board-watch plugin wakes an idle session. A wait loop would
  # cost one model call at each timeout.
  def test_opencode_worker_stops_and_the_plugin_wakes_it
    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    content = File.read(File.join(@dir, ".maf", "agents", "opencode", "backend-developer.md"))
    assert_includes content, "The board watcher wakes you"
    refute_includes content, "coord next --wait"
  end

  # Codex and Hermes cannot wake an idle session. They must block in
  # `coord next --wait`, which returns on a new task or a new message.
  def test_codex_worker_blocks_on_the_board_instead_of_stopping
    out, status = flow_with_home("--agent", "codex:backend-developer")

    assert_equal 0, status, out
    content = File.read(File.join(@dir, ".codex", "prompts", "backend-developer.md"))
    assert_includes content, "coord next --wait --timeout 540"
    refute_includes content, "next-task hook will re-prompt"
  end

  def test_codex_hooks_stay_in_the_project
    out, status = flow_with_home("--agent", "codex:backend-developer")
    assert_equal 0, status, out
    assert File.exist?(File.join(@dir, ".codex/hooks.json"))
    refute File.exist?(File.join(@dir, "home/.codex/hooks.json"))
    assert File.exist?(File.join(@dir, ".maf/coordination/harness-hooks/session-guard.rb"))
  end

  # Keep harness settings in a separate test home.
  def flow_with_home(*args)
    env = { "VAULT_SKIP" => "1", "HOME" => File.join(@dir, "home") }
    output = IO.popen(env, [RbConfig.ruby, *FLOW, "--project", @dir, "--no-bootstrap", *args],
                      err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end
end

class VaultTest < Minitest::Test
  def test_poll_interval_has_a_floor
    assert_operator Vault::POLL, :>=, Vault::MIN_POLL
  end

  # The watcher re-exports only when graph.json changed; every export
  # rewrites the Obsidian notes and makes Obsidian reload them.
  def test_tick_exports_only_when_the_graph_changes
    exports = 0
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(Vault::GRAPH_DIR)
        File.write(Vault::GRAPH, "{}")
        with_daemon_stubs(-> { exports += 1 }) do
          seen = Vault::Daemon.tick(nil)
          Vault::Daemon.tick(seen)
        end
      end
    end
    assert_equal 1, exports
  end

  def with_daemon_stubs(on_export)
    daemon = Vault::Daemon.singleton_class
    original = Vault::Daemon.method(:export)
    daemon.define_method(:system) { |*| true }
    daemon.define_method(:sleep) { |*| }
    daemon.define_method(:export) { on_export.call }
    yield
  ensure
    daemon.remove_method(:system, :sleep)
    daemon.define_method(:export, original)
  end
  # Regression: the Obsidian output dir shared its name with the `vault`
  # launcher script, so `graphify export obsidian --dir vault` failed with
  # FileExistsError. The two names must differ.
  def test_obsidian_dir_does_not_collide_with_the_launcher_name
    refute_equal "vault", Vault::DIR
  end

  # Regression: the wrapper called `graphify . --obsidian --obsidian-dir ...
  # --watch --mcp`, flags that graphify 0.9 removed. The export is now a
  # subcommand.
  def test_export_uses_the_current_graphify_subcommand
    assert_equal ["graphify", "export", "obsidian", "--dir", Vault::DIR], Vault::EXPORT_CMD
  end

  def test_no_removed_graphify_flags_are_used
    commands = (Vault::EXTRACT_CMD + Vault::UPDATE_CMD + Vault::EXPORT_CMD).join(" ")
    refute_match(/--obsidian-dir|--mcp|--watch|--obsidian\b/, commands)
  end
end

class SetupAgentTest < Minitest::Test
  # A lead role owns no task. Its launch prompt must not tell it to claim one.
  def test_hermes_prompt_for_a_lead_role_forbids_a_claim
    prompt = SetupAgent::Launcher::Hermes.prompt("project-manager")

    assert_includes prompt, "Never claim a task"
    assert_includes prompt, "coord inbox --wait"
  end

  def test_hermes_prompt_for_a_worker_role_claims_tasks
    assert_includes SetupAgent::Launcher::Hermes.prompt("tester"), "Claim a task"
  end

  def test_role_without_a_worker_suffix_defaults_to_one
    parsed = SetupAgent::Args.parse(%w[opencode backend-developer])

    assert_equal "opencode", parsed.harness
    assert_equal "backend-developer", parsed.role
    assert_equal "1", parsed.worker_id
    assert_equal "backend-developer-1", parsed.worker
    assert_nil parsed.model
  end

  def test_role_with_a_worker_suffix_and_a_model
    parsed = SetupAgent::Args.parse(["claude", "reviewer_2", "model:openrouter/x"])

    assert_equal "reviewer", parsed.role
    assert_equal "2", parsed.worker_id
    assert_equal "reviewer-2", parsed.worker
    assert_equal "openrouter/x", parsed.model
  end

  def test_model_flag
    parsed = SetupAgent::Args.parse(["opencode", "reviewer", "--model", "openrouter/x"])

    assert_equal "openrouter/x", parsed.model
    refute parsed.dispatch
    assert_empty parsed.dispatcher_args
  end

  # A dispatched instance defaults to worker "bot", so it never shares a
  # worktree with the interactive instance <role>-1.
  def test_dispatch_defaults_the_worker_to_bot
    parsed = SetupAgent::Args.parse(%w[hermes tester --dispatch])

    assert parsed.dispatch
    assert_equal "tester-bot", parsed.worker
  end

  def test_dispatch_forwards_other_flags_to_the_dispatcher
    parsed = SetupAgent::Args.parse(%w[hermes tester_2 --dispatch --model m --cache-window 1500 --once])

    assert_equal "m", parsed.model
    assert_equal "tester-2", parsed.worker
    assert_equal %w[--cache-window 1500 --once], parsed.dispatcher_args
  end

  def test_dispatch_may_come_first
    parsed = SetupAgent::Args.parse(%w[--dispatch hermes tester])

    assert parsed.dispatch
    assert_equal "hermes", parsed.harness
  end

  # Regression: a trailing `--model` with no value became the model name.
  def test_model_flag_needs_a_value
    assert_raises(SystemExit) { capture_io { SetupAgent::Args.parse(%w[hermes tester --dispatch --model]) } }
    assert_raises(SystemExit) { capture_io { SetupAgent::Args.parse(%w[hermes tester --dispatch --model --once]) } }
  end

  def test_dispatcher_flags_need_dispatch
    assert_raises(SystemExit) { capture_io { SetupAgent::Args.parse(%w[claude reviewer --interval 5]) } }
  end

  def test_dispatch_runs_the_worktree_dispatcher_with_harness_model_and_flags
    parsed = SetupAgent::Args.parse(%w[claude reviewer --dispatch --interval 30])
    ran = nil
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".maf/bin")
        FileUtils.touch(".maf/bin/dispatcher")
        with_exec_stub(->(cmd) { ran = cmd }) { SetupAgent::Dispatch.launch(parsed, "sonnet") }
      end
    end
    assert_equal [RbConfig.ruby, ".maf/bin/dispatcher", "reviewer", "--harness", "claude", "--model", "sonnet",
                  "--interval", "30"], ran
  end

  def wait_for_log(log, limit: 10)
    deadline = Time.now + limit
    sleep 0.1 until (File.exist?(log) && !File.zero?(log)) || Time.now > deadline
  end

  def test_detached_dispatcher_gets_the_worktree_as_pwd
    Dir.mktmpdir do |dir|
      worktree = File.realpath(dir)
      log = File.join(worktree, "out.log")
      Dir.chdir(worktree) do
        SetupAgent::Dispatch.spawn_detached(["printenv", "PWD"], log)
        wait_for_log(log)
      end
      assert_equal worktree, File.read(log).strip
    end
  end

  def test_dispatch_aborts_without_a_committed_dispatcher
    parsed = SetupAgent::Args.parse(%w[claude reviewer --dispatch])
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { assert_raises(SystemExit) { capture_io { SetupAgent::Dispatch.launch(parsed, nil) } } }
    end
  end

  def with_exec_stub(stub)
    launcher = SetupAgent::Launcher.singleton_class
    original = SetupAgent::Launcher.method(:exec_or_die)
    launcher.define_method(:exec_or_die) { |cmd| stub.call(cmd) }
    yield
  ensure
    launcher.define_method(:exec_or_die, original)
  end

  # Worktrees live inside the project, under <project>/.maf/worktrees/<slug>.
  def test_worktree_dir_is_inside_the_project
    assert_equal "/tmp/myproject/.maf/worktrees/tester-1",
                 SetupAgent::Worktree.dir_for("/tmp/myproject", "tester-1")
  end

  def test_manifest_verifies_a_known_agent_and_its_model
    manifest = SetupAgent::Manifest.new(
      [{ "harness" => "opencode", "role" => "backend-developer", "model" => "m" }]
    )

    manifest.verify!("opencode", "backend-developer")
    assert_equal "m", manifest.model_for("opencode", "backend-developer")
  end

  def test_manifest_rejects_an_unknown_agent
    manifest = SetupAgent::Manifest.new([])

    assert_raises(SystemExit) { capture_io { manifest.verify!("opencode", "nope") } }
  end

  # maf add keeps the current agents, so the hint names only the missing agent.
  def test_manifest_rejection_prints_the_maf_add_command
    manifest = SetupAgent::Manifest.new([{ "harness" => "claude", "role" => "reviewer" }])

    _out, err = capture_io { assert_raises(SystemExit) { manifest.verify!("opencode", "frontend-developer") } }
    assert_includes err, "maf add opencode:frontend-developer"
    refute_includes err, "claude:reviewer"
  end

  def test_hermes_launcher_is_registered
    SetupAgent::Launcher.register_defaults
    assert_kind_of Module, SetupAgent::Launcher.for("hermes")
  end

  # The skill name uses the main checkout's name, from the project root and
  # from a worktree alike (<project>/.maf/worktrees/<slug> -> <project>-<role>).
  def test_hermes_skill_name_is_the_same_in_root_and_worktree
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    in_project_with_worktree do |root, worktree|
      Dir.chdir(root) { assert_equal "myproject-tester", SetupAgent::HermesSkill.name("tester") }
      Dir.chdir(worktree) { assert_equal "myproject-tester", SetupAgent::HermesSkill.name("tester") }
    end
  end

  # flow.rb records a custom --hermes-dir in the manifest; the launcher must
  # look for the skill there, not in a different default.
  def test_hermes_skill_dir_comes_from_the_manifest
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    in_project_with_worktree do |root, worktree|
      File.write(File.join(root, ".maf/config.json"), JSON.generate(hermes_dir: File.join(root, "skills")))
      FileUtils.mkdir_p(File.join(root, "skills", "myproject-tester"))
      FileUtils.touch(File.join(root, "skills", "myproject-tester", "SKILL.md"))
      Dir.chdir(worktree) { assert SetupAgent::HermesSkill.installed?("tester") }
    end
  end

  def in_project_with_worktree
    Dir.mktmpdir do |parent|
      root = File.join(File.realpath(parent), "myproject")
      FileUtils.mkdir_p(root)
      git(root, "init", "-q")
      git(root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
      worktree = File.join(root, ".maf/worktrees", "slug")
      git(root, "worktree", "add", "-q", worktree)
      yield root, worktree
    end
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || flunk("git #{args.first} failed")
  end
end

# HermesHook answers the two questions the installer must not guess: is the
# hook declared in the Hermes config, and is it approved. Hermes ties the
# approval to the script version, so an updated script needs a new approval.
# Every method takes a path, so fixtures cover the logic with no Hermes install.
class HermesHookTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("hermes-hook-test"))
    @script = File.join(@dir, "next-task.sh")
    File.write(@script, "#!/bin/sh\n")
    @config = File.join(@dir, "config.yaml")
    @allowlist = File.join(@dir, "allowlist.json")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_declared_when_the_config_names_the_script
    File.write(@config, "hooks:\n  on_session_end:\n    - command: #{@script}\n")

    assert Flow::HermesHook.declared?(@config, @script)
  end

  def test_not_declared_without_a_config_file
    refute Flow::HermesHook.declared?(@config, @script)
  end

  def test_not_declared_when_the_config_names_another_hook
    File.write(@config, "hooks:\n  on_session_end:\n    - command: /tmp/other-hook.sh\n")

    refute Flow::HermesHook.declared?(@config, @script)
  end

  def test_approved_for_a_matching_entry
    write_allowlist(recorded: recorded)

    assert Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  # Hermes records the approval time rounded to microseconds. Ruby reports the
  # file time with finer precision, so an exact match would never hold.
  def test_approved_when_the_recorded_time_is_one_microsecond_late
    write_allowlist(recorded: recorded(0.000_001))

    assert Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  def test_not_approved_after_the_script_changes
    write_allowlist(recorded: recorded(-60))

    refute Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  def test_not_approved_for_another_event
    write_allowlist(recorded: recorded, event: "pre_tool_call")

    refute Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  def test_not_approved_without_an_allowlist_file
    refute Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  def test_not_approved_without_a_recorded_time
    write_allowlist(recorded: nil)

    refute Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  def test_not_approved_when_the_allowlist_is_corrupt
    File.write(@allowlist, "{ not json")

    refute Flow::HermesHook.approved?(@allowlist, @script, File.mtime(@script))
  end

  def test_config_command_names_the_hook_and_the_event
    command = Flow::HermesHook.config_command(@script)

    assert_includes command, "hermes config set hooks.on_session_end"
    assert_includes command, @script
    assert_includes command, "timeout"
  end

  def recorded(offset = 0)
    (File.mtime(@script) + offset).utc.iso8601(6)
  end

  def write_allowlist(recorded:, event: "on_session_end")
    entry = { "approved_at" => Time.now.utc.iso8601(6), "command" => @script,
              "event" => event, "script_mtime_at_approval" => recorded }
    File.write(@allowlist, JSON.pretty_generate("approvals" => [entry]))
  end
end

# The commit guard is a git pre-commit hook. It blocks commits by roles with
# can_edit false. `git merge` does not run pre-commit, so merges still pass.
class CommitGuardTest < InstallerTestCase
  HOOK = File.join(ROOT, "assets", "git-hooks", "pre-commit")

  def setup
    super
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    git("init", "-q", "-b", "main")
    commit("init")
  end

  def git(*args, env: {})
    system(env, "git", "-C", @dir, "-c", "user.email=t@t", "-c", "user.name=t", *args,
           out: File::NULL, err: File::NULL)
  end

  def commit(message, env: {}) = git("commit", "-q", "--allow-empty", "-m", message, env: env)
  def hook_path = File.join(@dir, ".git", "hooks", "pre-commit")

  def install_guard
    FileUtils.cp(HOOK, hook_path)
    agents = [{ role: "reviewer", can_edit: false }, { role: "tester", can_edit: true }]
    FileUtils.mkdir_p(File.join(@dir, ".maf"))
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(agents: agents))
  end

  def test_refuses_a_commit_by_a_read_only_role
    install_guard

    refute commit("review edit", env: { "COORD_ROLE" => "reviewer" })
  end

  def test_allows_a_commit_by_an_editing_role_and_by_a_human
    install_guard

    assert commit("tester edit", env: { "COORD_ROLE" => "tester" })
    assert commit("human edit")
  end

  def test_allows_a_merge_by_a_read_only_role
    install_guard
    git("checkout", "-q", "-b", "task/1")
    commit("task work")
    git("checkout", "-q", "main")
    commit("other work")

    assert git("merge", "-q", "--no-edit", "task/1", env: { "COORD_ROLE" => "reviewer" })
  end

  def bootstrap(*args) = run_ruby(BOOTSTRAP, @dir, "--roles", "architect", *args)

  def test_bootstrap_installs_the_guard
    out, status = bootstrap

    assert_equal 0, status, out
    assert File.executable?(hook_path)
    assert_includes File.read(hook_path), "commit-guard - git pre-commit hook"
  end

  def test_bootstrap_keeps_a_foreign_hook_even_with_force
    File.write(hook_path, "#!/bin/sh\nmake lint\n")

    out, = bootstrap("--force")

    assert_equal "#!/bin/sh\nmake lint\n", File.read(hook_path)
    assert_includes out, "the commit guard is off"
  end
end

# The doc-graph refresh runs from the shared git hooks. A foreign post-commit
# hook (graphify installs one) must stay; the installer owns only its block.
class DocGraphHookTest < InstallerTestCase
  def setup
    super
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    system("git", "-C", @dir, "init", "-q", exception: true)
  end

  def bootstrap(*args) = run_ruby(BOOTSTRAP, @dir, "--roles", "architect", *args)

  def hook(name) = File.join(@dir, ".git", "hooks", name)

  def test_installs_the_refresh_script
    out, status = bootstrap

    assert_equal 0, status, out
    script = File.join(@dir, ".maf/bin", "doc-graph-refresh")
    assert File.executable?(script)
    assert_includes File.read(script), "doc-graph-refresh - rebuild the knowledge graph after a markdown change."
  end

  def test_appends_the_block_to_both_hooks
    bootstrap

    %w[post-commit post-merge].each do |name|
      assert_includes File.read(hook(name)), "doc-graph-refresh\" #{name}"
      assert File.executable?(hook(name))
    end
  end

  def test_keeps_a_foreign_post_commit_hook
    FileUtils.mkdir_p(File.dirname(hook("post-commit")))
    File.write(hook("post-commit"), "#!/bin/sh\nmake lint\n")

    bootstrap

    content = File.read(hook("post-commit"))
    assert_includes content, "make lint"
    assert_includes content, ">>> multi-agent-flow >>>"
    assert_operator content.index(">>> multi-agent-flow >>>"), :<, content.index("make lint")
  end

  def test_skips_a_foreign_hook_with_a_non_sh_shebang
    FileUtils.mkdir_p(File.dirname(hook("post-commit")))
    File.write(hook("post-commit"), "#!/usr/bin/env ruby\nputs 1\n")

    out, = bootstrap

    assert_equal "#!/usr/bin/env ruby\nputs 1\n", File.read(hook("post-commit"))
    assert_includes out, "non-sh shebang"
  end

  def test_check_lists_the_new_hook
    out, = bootstrap("--check")

    assert_includes out, "doc-graph-refresh"
    assert_includes out, "post-commit"
    assert_includes out, "post-merge"
  end

  def test_rerun_keeps_one_block
    bootstrap
    bootstrap

    assert_equal 1, File.read(hook("post-commit")).scan(">>> multi-agent-flow >>>").size
  end
end
