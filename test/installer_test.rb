#!/usr/bin/env ruby
# frozen_string_literal: true

# test/installer_test.rb - tests for the installer layer:
# assets/bootstrap.rb, scripts/flow.rb, and assets/setup_agent.
#
# Run: ruby test/installer_test.rb
#
# bootstrap.rb and flow.rb run their work when loaded, so the tests invoke
# them as subprocesses against a disposable project directory. setup_agent is
# loaded directly (its entry point is guarded) so its parsing can be unit
# tested. No external tools (task, git, graphify) are required.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
BOOTSTRAP = File.join(ROOT, "assets", "bootstrap.rb")
FLOW = File.join(ROOT, "scripts", "flow.rb")
load File.join(ROOT, "assets", "setup_agent")
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
    output = IO.popen({ "VAULT_SKIP" => "1" }, [RbConfig.ruby, script, *args],
                      err: [:child, :out], &:read)
    [output, $?.exitstatus]
  end
end

class BootstrapTest < InstallerTestCase
  def bootstrap(*args)
    run_ruby(BOOTSTRAP, @dir, "--roles", "architect,backend-developer", *args)
  end

  def taskrc_path = File.join(@dir, "coordination", "taskrc")

  def test_installs_coordination_layer
    out, status = bootstrap

    assert_equal 0, status, out
    assert File.executable?(File.join(@dir, "coord"))
    assert File.executable?(File.join(@dir, "setup_agent"))
    assert_includes File.read(taskrc_path), "data.location=#{File.join(@dir, "coordination", "taskdata")}"
    assert_includes File.read(File.join(@dir, "AGENTS.md")), ">>> multi-agent-flow >>>"
    assert_includes File.read(File.join(@dir, ".gitignore")), "coord-env.sh"
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
    File.write(File.join(@dir, "coord"), "# someone else's tool\n")

    out, status = bootstrap

    assert_equal 0, status, out
    assert_includes out, "REFUSE"
    assert_equal "# someone else's tool\n", File.read(File.join(@dir, "coord"))
  end

  # Regression: a pre-existing, non-flow coordination/taskrc must never be
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
    assert_includes content, "data.location=#{File.join(@dir, "coordination", "taskdata")}"
    assert_includes content, "uda.role.type=string"
  end

  def test_check_writes_nothing
    out, status = bootstrap("--check")

    assert_equal 0, status, out
    assert_includes out, "--check: no changes made."
    refute File.exist?(File.join(@dir, "coord"))
    refute File.exist?(taskrc_path)
  end

  # Regression: vault auto-start spawns a detached daemon. VAULT_SKIP must stop
  # it, so bootstrap in tests/CI never leaves an orphan process behind.
  def test_vault_skip_prevents_auto_start
    out, status = bootstrap

    assert_equal 0, status, out
    assert_includes out, "skipped (VAULT_SKIP is set)"
    refute File.exist?(File.join(@dir, "coordination", "vault.pid"))
  end

  def test_adds_board_watch_hooks_to_claude_settings_once
    settings_path = File.join(@dir, ".claude", "settings.json")
    FileUtils.mkdir_p(File.dirname(settings_path))
    File.write(settings_path, JSON.generate(hooks: { Stop: [{ matcher: "", hooks: [{ type: "command",
                                                     command: "ruby coordination/harness-hooks/next-task.rb" }] }] }))
    2.times { assert_equal 0, bootstrap.last }

    hooks = JSON.parse(File.read(settings_path))["hooks"]
    watch = hooks["SessionStart"].map { |entry| entry["hooks"][0] }
    assert_equal [true], watch.map { |hook| hook["asyncRewake"] }
    assert_equal ["ruby coordination/harness-hooks/board-watch.rb"], watch.map { |hook| hook["command"] }
    assert_equal 2, hooks["Stop"].size
    assert File.exist?(File.join(@dir, "coordination", "harness-hooks", "board-watch.rb"))
    assert Dir.exist?(File.join(@dir, "coordination", "message-hooks"))
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
    run_ruby(FLOW, "--project", @dir, "--no-bootstrap", *args)
  end

  def agent_file = File.join(@dir, ".opencode", "agents", "backend-developer.md")
  def architect_file = File.join(@dir, ".opencode", "agents", "architect.md")
  def manifest = JSON.parse(File.read(File.join(@dir, ".agent-flow.json")))

  def test_generates_agent_file_and_manifest
    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    assert File.exist?(agent_file)
    assert_equal [{ "harness" => "opencode", "role" => "backend-developer", "model" => nil }],
                 manifest["agents"]
  end

  def test_is_idempotent
    flow("--agent", "opencode:backend-developer")
    first = File.read(agent_file)

    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    assert_includes out, "skip"
    assert_equal first, File.read(agent_file)
  end

  def test_refuses_a_foreign_agent_file
    FileUtils.mkdir_p(File.dirname(agent_file))
    File.write(agent_file, "# hand-written agent\n")

    out, status = flow("--agent", "opencode:backend-developer")

    assert_equal 0, status, out
    assert_includes out, "refuse"
    assert_equal "# hand-written agent\n", File.read(agent_file)
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
    assert_includes content, "./coord add --role <role>"
    refute_match(/COORD_AGENT|coord add --agent/, content)
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
    out, status = run_ruby(FLOW, "--project", @dir, "--agent", "claude:backend-developer")

    assert_equal 0, status, out
    settings = JSON.parse(File.read(File.join(@dir, ".claude", "settings.json")))
    commands = settings["hooks"]["SessionStart"].map { |entry| entry["hooks"][0]["command"] }
    assert_includes commands, "ruby coordination/harness-hooks/board-watch.rb"
  end

  def test_claude_worker_stops_and_the_board_watcher_wakes_it
    out, status = flow("--agent", "claude:backend-developer")

    assert_equal 0, status, out
    content = File.read(File.join(@dir, ".claude", "agents", "backend-developer.md"))
    assert_includes content, "The board watcher wakes you"
    refute_includes content, "coord next --wait"
  end

  # Only Claude Code can wake an idle session. Other harnesses must block in
  # `coord next --wait`, which returns on a new task or a new message.
  def test_codex_worker_blocks_on_the_board_instead_of_stopping
    out, status = flow_with_home("--agent", "codex:backend-developer")

    assert_equal 0, status, out
    content = File.read(File.join(@dir, ".codex", "prompts", "backend-developer.md"))
    assert_includes content, "./coord next --wait --timeout 540"
    refute_includes content, "next-task hook will re-prompt"
  end

  # Codex hooks install into HOME, so keep HOME inside the test directory.
  def flow_with_home(*args)
    env = { "VAULT_SKIP" => "1", "HOME" => @dir }
    output = IO.popen(env, [RbConfig.ruby, FLOW, "--project", @dir, "--no-bootstrap", *args],
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
        FileUtils.mkdir_p("graphify-out")
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
        FileUtils.touch("dispatcher")
        with_exec_stub(->(cmd) { ran = cmd }) { SetupAgent::Dispatch.launch(parsed, "sonnet") }
      end
    end
    assert_equal [RbConfig.ruby, "./dispatcher", "reviewer", "--harness", "claude", "--model", "sonnet",
                  "--interval", "30"], ran
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

  # Worktrees live inside the project, under <project>/.worktrees/<slug>.
  def test_worktree_dir_is_inside_the_project
    assert_equal "/tmp/myproject/.worktrees/tester-1",
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

  # flow.rb lives in multi_agent_flow, not in the project. flow.rb also
  # rewrites the whole manifest, so the hint must keep the current agents.
  def test_manifest_rejection_prints_the_full_flow_command
    manifest = SetupAgent::Manifest.new([{ "harness" => "claude", "role" => "reviewer" }])

    _out, err = capture_io { assert_raises(SystemExit) { manifest.verify!("opencode", "frontend-developer") } }
    assert_includes err, 'ruby "$FLOW/scripts/flow.rb" --project "$PWD"'
    assert_includes err, "--agent claude:reviewer --agent opencode:frontend-developer"
  end

  def test_hermes_launcher_is_registered
    SetupAgent::Launcher.register_defaults
    assert_kind_of Module, SetupAgent::Launcher.for("hermes")
  end

  # The skill name uses the main checkout's name, from the project root and
  # from a worktree alike (<project>/.worktrees/<slug> -> <project>-<role>).
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
      File.write(File.join(root, ".agent-flow.json"), JSON.generate(hermes_dir: File.join(root, "skills")))
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
      worktree = File.join(root, ".worktrees", "slug")
      git(root, "worktree", "add", "-q", worktree)
      yield root, worktree
    end
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || flunk("git #{args.first} failed")
  end
end
