# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/maf/flow"
require_relative "../lib/maf/uninstall"

class HookConfigCase < Minitest::Test
  def setup = @dir = Dir.mktmpdir("maf-hook-config")
  def teardown = FileUtils.remove_entry(@dir)
  def path = File.join(@dir, ".codex", "hooks.json")
  def read = JSON.parse(File.read(path))

  def write(data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def foreign_hook = { "type" => "command", "command" => "ruby user-hook.rb" }
end

class CodexProjectHooksTest < HookConfigCase
  def test_installs_project_hooks_without_global_files
    Flow::CodexHooks.new(@dir).install
    assert_equal %w[SessionStart Stop], read.fetch("hooks").keys
    refute File.exist?(File.join(@dir, ".codex/hooks/next-task.rb"))
  end

  def test_preserves_other_hooks_and_is_idempotent
    write("hooks" => { "Stop" => [{ "hooks" => [foreign_hook] }] }, "description" => "User hooks")
    2.times { Flow::CodexHooks.new(@dir).install }
    assert_equal 2, read.dig("hooks", "Stop").size
    assert_equal foreign_hook, read.dig("hooks", "Stop", 0, "hooks", 0)
    assert_equal "User hooks", read.fetch("description")
  end

  def test_corrupt_configuration_is_not_overwritten
    write({})
    File.write(path, "broken")
    assert_raises(JSON::ParserError) { Flow::CodexHooks.new(@dir).install }
    assert_equal "broken", File.read(path)
  end

  def test_uninstall_removes_only_maf_project_hooks
    write("hooks" => { "Stop" => [{ "hooks" => [foreign_hook] }] })
    Flow::CodexHooks.new(@dir).install
    Uninstall::CodexHooks.new(@dir).steps.each(&:run)
    assert_equal({ "hooks" => { "Stop" => [{ "hooks" => [foreign_hook] }] } }, read)
  end

  def test_uninstall_removes_an_empty_owned_hook_file
    Flow::CodexHooks.new(@dir).install
    Uninstall::CodexHooks.new(@dir).steps.each(&:run)
    refute File.exist?(path)
  end
end

class LegacyCodexHookTest < HookConfigCase
  def script = File.join(@dir, ".codex/hooks/next-task.rb")
  def legacy_hook = { "type" => "command", "command" => "ruby #{script}" }

  def prepare_legacy
    FileUtils.mkdir_p(File.dirname(script))
    File.write(script, "# next-task.rb - Stop hook for Claude Code and Codex.\n")
    write("hooks" => { "Stop" => [{ "matcher" => "", "hooks" => [foreign_hook, legacy_hook] }] })
  end

  def remove_legacy
    capture_io { Flow::LegacyCodexHook.new(@dir).remove }
  end

  def test_removes_only_the_owned_global_registration
    prepare_legacy
    remove_legacy
    assert_equal [foreign_hook], read.dig("hooks", "Stop", 0, "hooks")
    assert_equal "", read.dig("hooks", "Stop", 0, "matcher")
  end

  def test_cached_global_hook_commands_cannot_steer_a_session
    prepare_legacy
    File.open(script, "a") { |file| file.puts("puts 'claim another task'") }
    remove_legacy
    assert_empty IO.popen([RbConfig.ruby, script], &:read)
    assert $?.success?
  end

  def test_does_not_remove_a_foreign_script_with_the_same_name
    prepare_legacy
    File.write(script, "# User hook\n")
    remove_legacy
    assert_equal [foreign_hook, legacy_hook], read.dig("hooks", "Stop", 0, "hooks")
  end

  def test_corrupt_global_configuration_is_not_overwritten
    prepare_legacy
    File.write(path, "broken")
    remove_legacy
    assert_equal "broken", File.read(path)
  end

  def test_empty_groups_are_removed_and_other_events_stay
    prepare_legacy
    write("hooks" => { "Stop" => [{ "hooks" => [legacy_hook] }], "SessionStart" => [{ "hooks" => [foreign_hook] }] })
    remove_legacy
    assert_equal({ "SessionStart" => [{ "hooks" => [foreign_hook] }] }, read.fetch("hooks"))
  end
end
