#!/usr/bin/env ruby
# frozen_string_literal: true

# test/migrate_test.rb - tests for lib/maf/migrate.rb.
#
# Run: ruby test/migrate_test.rb
#
# Each test builds a small old-layout install in a disposable git project,
# then runs the migration as a subprocess. Tests skip when git is absent.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
LIB = File.join(ROOT, "lib", "maf")
MIGRATE = ["-r", File.join(LIB, "migrate.rb"), "-e", "Migrate::Runner.new(ARGV).run", "--"].freeze
MAF = File.join(ROOT, "bin", "maf")

class MigrateTestCase < Minitest::Test
  OLD_HOOKS = { "hooks" => { "Stop" => [{ "matcher" => "", "hooks" => [
    { "type" => "command", "command" => "ruby coordination/harness-hooks/next-task.rb" }
  ] }] } }.freeze

  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    @dir = File.realpath(Dir.mktmpdir("flow-migrate-test"))
    git("init", "-q")
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
    build_old_install
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def path(*parts) = File.join(@dir, *parts)
  def git(*args) = system("git", "-C", @dir, *args, exception: true)

  def write(rel, content)
    FileUtils.mkdir_p(File.dirname(path(rel)))
    File.write(path(rel), content)
  end

  def build_old_install
    %w[coord dispatcher dashboard vault].each { |name| FileUtils.cp(File.join(ROOT, "assets", name), path(name)) }
    write(".agent-flow.json", JSON.generate(agents: [{ harness: "claude", role: "architect", can_edit: false }]))
    write("coordination/taskrc", "data.location=#{@dir}/coordination/taskdata\n")
    write("coordination/inbox/architect/msg.md", "hello\n")
    write("coordination/doc-graph-refresh", "# doc-graph-refresh - rebuild the knowledge graph after a markdown change.\n")
    write(".claude/agents/architect.md", "<!-- >>> multi-agent-flow >>> -->\nrole\n")
    write(".claude/settings.json", JSON.generate(OLD_HOOKS))
    write("graphify-out/graph.json", "{}")
    write("obsidian/note.md", "note")
    add_worktree
  end

  def add_worktree
    git("worktree", "add", "-q", "-b", "worker/tester-1", ".worktrees/tester-1")
    write(".worktrees/tester-1/coord-env.sh", "export COORD_DIR=#{@dir}/coordination\nexport COORD_SLOT=1\n")
    write("coordination/workers.json", JSON.generate("tester-1" => { "dir" => "#{@dir}/.worktrees/tester-1" }))
  end

  def migrate(*args, stdin: "")
    out, status = Open3.capture2e({ "VAULT_SKIP" => "1" }, RbConfig.ruby, *MIGRATE, "--project", @dir, *args,
                                  stdin_data: stdin)
    [out, status.exitstatus]
  end
end

class MigrateMovesTest < MigrateTestCase
  def test_moves_the_scripts_and_the_folders_into_the_flow_folder
    out, status = migrate("--yes")

    assert_equal 0, status, out
    %w[coord dispatcher dashboard vault doc-graph-refresh].each do |name|
      assert File.exist?(path(".maf", "bin", name)), "#{name} missing in .maf/bin"
    end
    assert File.exist?(path(".maf", "coordination", "inbox", "architect", "msg.md"))
    assert File.exist?(path(".maf", "graphify-out", "graph.json"))
    assert File.exist?(path(".maf", "obsidian", "note.md"))
    assert File.exist?(path(".maf", "config.json"))
  end

  def test_leaves_only_the_flow_folder_the_text_files_and_the_harness_folders_at_the_root
    out, status = migrate("--yes")

    assert_equal 0, status, out
    assert_equal %w[.claude .git .gitignore .maf .mcp.json AGENTS.md], Dir.children(@dir).sort
  end

  def test_rewrites_the_paths_inside_the_files
    migrate("--yes")

    assert_includes File.read(path(".maf", "coordination", "taskrc")), "data.location=#{@dir}/.maf/coordination/taskdata"
    assert_includes File.read(path(".maf", "coordination", "workers.json")), "#{@dir}/.maf/worktrees/tester-1"
    settings = File.read(path(".claude", "settings.json"))
    assert_includes settings, "ruby .maf/coordination/harness-hooks/next-task.rb"
    refute_includes settings, "ruby coordination/harness-hooks"
  end

  def test_moves_the_worktree_with_git_and_writes_its_env_file
    out, status = migrate("--yes")

    assert_equal 0, status, out
    refute Dir.exist?(path(".worktrees"))
    assert_includes `git -C #{@dir} worktree list --porcelain`, "#{@dir}/.maf/worktrees/tester-1"
    env = File.read(path(".maf", "worktrees", "tester-1", ".maf", "env.sh"))
    assert_includes env, "COORD_DIR=#{@dir}/.maf/coordination"
    assert_includes env, "MAF_BIN=#{@dir}/.maf/bin"
    refute File.exist?(path(".maf", "worktrees", "tester-1", "coord-env.sh"))
  end

  def test_moves_a_role_file_and_links_the_harness_folder
    out, status = migrate("--yes")

    assert_equal 0, status, out
    assert File.exist?(path(".maf", "agents", "claude", "architect.md"))
    assert_equal "../.maf/agents/claude", File.readlink(path(".claude", "agents"))
  end
end

class MigrateSafetyTest < MigrateTestCase
  def test_check_changes_nothing
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |f| f.start_with?(".git/") }.sort

    out, status = migrate("--check")

    assert_equal 0, status, out
    assert_includes out, "move   coord -> .maf/bin/coord"
    assert_equal before, Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |f| f.start_with?(".git/") }.sort
  end

  def test_declined_confirmation_changes_nothing
    out, status = migrate(stdin: "n\n")

    assert_equal 1, status, out
    assert File.exist?(path("coord"))
  end

  def test_keeps_a_foreign_script_with_the_name_of_a_flow_script
    write("vault", "#!/bin/sh\necho mine\n")

    migrate("--yes")

    assert_equal "#!/bin/sh\necho mine\n", File.read(path("vault"))
  end

  def test_keeps_a_foreign_file_in_a_harness_folder
    write(".claude/agents/mine.md", "my agent\n")

    migrate("--yes")

    assert File.exist?(path(".claude", "agents", "mine.md"))
    refute File.symlink?(path(".claude", "agents"))
  end

  def test_keeps_the_old_file_when_the_new_path_exists
    write(".maf/bin/coord", "# new\n")

    out, = migrate("--yes")

    assert_includes out, "keep   coord"
    assert File.exist?(path("coord"))
    assert_equal "# new\n", File.read(path(".maf", "bin", "coord"))
  end

  def test_reports_nothing_to_migrate_in_a_new_project
    FileUtils.rm_rf(%w[coord dispatcher dashboard vault .agent-flow.json coordination].map { |f| path(f) })

    out, status = migrate("--yes")

    assert_equal 0, status, out
    assert_includes out, "nothing to migrate"
  end

  def test_a_second_run_finds_nothing_to_migrate
    migrate("--yes")

    out, status = migrate("--yes")

    assert_equal 0, status, out
    assert_includes out, "nothing to migrate"
  end
end

class MigrateHintTest < MigrateTestCase
  def maf(*args)
    out, status = Open3.capture2e({ "VAULT_SKIP" => "1" }, RbConfig.ruby, MAF, *args, chdir: @dir)
    [out, status.exitstatus]
  end

  def test_update_prints_the_migrate_hint_on_an_old_layout
    out, status = maf("update")

    refute_equal 0, status
    assert_includes out, "maf migrate"
  end

  def test_help_works_on_an_old_layout
    out, status = maf("help")

    assert_equal 0, status, out
    assert_includes out, "migrate"
  end
end
