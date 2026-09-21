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
    output = IO.popen([RbConfig.ruby, script, *args], err: [:child, :out], &:read)
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
    File.write(taskrc_path, "# >>> multi-agent-flow >>>\nuda.agent.type=string\n")

    out, status = bootstrap

    assert_equal 0, status, out
    content = File.read(taskrc_path)
    assert_includes content, "data.location=#{File.join(@dir, "coordination", "taskdata")}"
    assert_includes content, "uda.agent.type=string"
  end

  def test_check_writes_nothing
    out, status = bootstrap("--check")

    assert_equal 0, status, out
    assert_includes out, "--check: no changes made."
    refute File.exist?(File.join(@dir, "coord"))
    refute File.exist?(taskrc_path)
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

  # Worktrees are grouped under one sibling folder, <project>.worktrees/<slug>.
  def test_worktree_dir_is_grouped_under_the_worktrees_folder
    assert_equal "/tmp/myproject.worktrees/tester-1",
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
end
