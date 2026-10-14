#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_references_test.rb - tests for lib/maf/shared/sandbox/references.rb.
#
# Run: ruby test/sandbox_references_test.rb
require_relative "sandbox_helper"

class SandboxReferencesTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def denials(harness) = Sandbox.wrap(CMD, harness)[2].split("(deny file-write*\n").last
  def subpath(dir, path) = "(subpath \"#{dir}/#{path}\")"
  def codex_denials(dir) = with_env("CODEX_HOME" => "#{dir}/codex") { denials(harness("codex")) }

  def test_the_profile_protects_a_script_that_the_harness_config_names
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write_notify_config(dir)
      assert_includes codex_denials(dir), subpath(dir, "codex/notify.sh")
      refute_includes codex_denials(dir), "/usr/bin/true"
    end
  end

  def write_notify_config(dir)
    write("codex/notify.sh", "")
    write("codex/config.toml", %(notify = ["#{dir}/codex/notify.sh", "/usr/bin/true"]\n))
  end

  def test_the_profile_protects_the_imports_of_claude_md
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      { "CLAUDE.md" => "Read @RTK.md\n", "RTK.md" => "@~/more.md\n", "more.md" => "" }
        .each { |name, text| write("claude/#{name}", text) }
      %w[claude/RTK.md claude/more.md].each { |path| assert_includes claude_denials(dir), subpath(dir, path) }
    end
  end

  def test_the_profile_protects_a_relative_script_and_a_large_file
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write_hooks(dir)
      %w[scripts/hook.sh bin/hook].each { |path| assert_includes codex_denials(dir), subpath(dir, path) }
    end
  end

  def test_the_profile_protects_a_hook_in_the_project_dir_variable
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      %w[scripts/a.sh scripts/b.sh].each { |path| write(path, "") }
      write(".claude/settings.json", '{"hooks": "$CLAUDE_PROJECT_DIR/scripts/a.sh ${CLAUDE_PROJECT_DIR}/scripts/b.sh"}')
      assert_equal([true, true], protected?(dir, %w[scripts/a.sh scripts/b.sh]))
    end
  end

  def test_the_profile_protects_a_script_that_the_config_of_a_worktree_names
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write(".maf/worktrees/w1/scripts/hook.sh", "")
      write(".maf/worktrees/w1/.claude/settings.json", '{"hooks": "scripts/hook.sh"}')
      assert_equal([true], protected?(dir, %w[.maf/worktrees/w1/scripts/hook.sh]))
    end
  end

  def test_the_profile_protects_the_flow_config_and_its_scripts
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write_flow_config
      assert_equal([true] * 4, protected?(dir, %w[.maf/claude .maf/mcp scripts/a.sh scripts/b.sh]))
    end
  end

  def write_flow_config
    %w[scripts/a.sh scripts/b.sh].each { |path| write(path, "") }
    write(".maf/claude/settings.json", '{"hooks": "scripts/a.sh"}')
    write(".maf/mcp/claude.json", '{"mcpServers": "scripts/b.sh"}')
  end

  def write_hooks(dir)
    write("scripts/hook.sh", "")
    write("bin/hook", "x" * Sandbox::References::MAX_SIZE)
    write("codex/config.toml", %(notify = ["sh", "scripts/hook.sh", "#{dir}/bin/hook"]\n))
  end

  def test_a_markdown_file_protects_only_its_imports
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      %w[lib/app.rb notes.md].each { |path| write(path, "") }
      write("claude/CLAUDE.md", "Read @../notes.md. Edit lib/app.rb or #{dir}/lib/app.rb.\n")
      assert_equal([true, false], protected?(dir, %w[notes.md lib/app.rb]))
    end
  end

  def test_a_permission_rule_does_not_protect_its_file
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write("lib/app.rb", "")
      write("claude/settings.json", JSON.generate("permissions" => { "allow" => ["Edit(lib/app.rb)"] }))
      refute_includes claude_denials(dir), subpath(dir, "lib/app.rb")
    end
  end

  IMPORTS = { "home/CLAUDE.md" => "@RTK.md\n", "home/RTK.md" => "@../app/notes.md\n", "app/notes.md" => "" }.freeze

  def test_the_scan_follows_a_file_that_the_filter_drops
    in_tmpdir do |dir|
      IMPORTS.each { |path, text| write(path, text) }
      kept = Sandbox::References.of(["#{dir}/home/CLAUDE.md"], dir, ->(path) { path.include?("/app/") })
      assert_equal ["#{dir}/app/notes.md"], kept
    end
  end

  def protected?(dir, paths) = claude_denials(dir).then { |text| paths.map { |p| text.include?(subpath(dir, p)) } }

  def claude_denials(dir)
    with_env("CLAUDE_CONFIG_DIR" => "#{dir}/claude", "HOME" => "#{dir}/claude") { denials(harness("claude")) }
  end
end
