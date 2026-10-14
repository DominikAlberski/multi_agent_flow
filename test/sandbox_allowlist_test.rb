#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_allowlist_test.rb - tests for lib/maf/shared/sandbox/harness_files.rb
# and the config paths of the project in lib/maf/shared/sandbox/paths.rb.
#
# Run: ruby test/sandbox_allowlist_test.rb
require_relative "sandbox_helper"

class SandboxAllowlistTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def denials(harness) = profile(harness).split("(deny file-write*\n").last
  def profile(harness) = Sandbox.wrap(CMD, harness)[2]
  def subpath(dir, path) = "(subpath \"#{dir}/#{path}\")"
  def codex_denials(dir) = with_env("CODEX_HOME" => "#{dir}/codex") { denials(harness("codex")) }

  def test_the_profile_allows_the_state_paths_of_the_harness
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      assert_includes Sandbox.wrap(CMD, harness("codex"))[2], state_rule(harness("codex").home, "sessions")
    end
  end

  def test_the_profile_protects_each_path_of_a_harness_that_is_not_state
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      %w[codex/new-plugins codex/sessions].each { |path| FileUtils.mkdir_p(path) }
      assert_includes codex_denials(dir), subpath(dir, "codex/new-plugins")
      refute_includes codex_denials(dir), subpath(dir, "codex/sessions")
    end
  end

  def test_the_profile_does_not_open_a_whole_folder_of_a_harness
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      rules = with_env("CODEX_HOME" => "#{dir}/codex") { profile(harness("codex")) }.split("(deny file-write*\n")
      refute_includes rules.first, "(subpath \"#{dir}/codex\")"
    end
  end

  def test_the_profile_does_not_open_the_shared_caches
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      %w[.cache Library/Caches].each { |path| refute_includes profile(harness("claude")), subpath(Dir.home, path) }
    end
  end

  def test_the_profile_protects_the_harness_config_in_the_project
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      denials = denials(harness("codex"))
      [".mcp.json", ".claude/settings.json", ".opencode"].each { |path| assert_includes denials, subpath(dir, path) }
    end
  end

  def test_the_profile_protects_the_flow_in_a_worktree
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      FileUtils.mkdir_p(".maf/worktrees/w1/.maf/bin")
      assert_includes denials(harness("claude")), subpath(dir, ".maf/worktrees/w1/.maf/bin")
    end
  end

  def test_a_relative_write_path_starts_at_the_project_root
    in_project("sandbox" => { "mode" => "seatbelt", "write" => ["cache"] }) do |dir|
      profile = Dir.chdir(FileUtils.mkdir_p("sub").first) { profile(harness("claude")) }
      assert_includes profile, "(subpath \"#{dir}/cache\")"
    end
  end

  def test_the_profile_protects_the_harness_hooks
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      hooks = [".maf/coordination/harness-hooks", ".maf/worktrees/w1/.maf/coordination/harness-hooks"]
      FileUtils.mkdir_p(hooks)
      hooks.each { |path| assert_includes denials(harness("claude")), subpath(dir, path) }
    end
  end

  def test_bwrap_protects_each_path_of_a_harness_that_is_not_state
    in_project("sandbox" => { "mode" => "bwrap" }) do |dir|
      %w[home/.claude/new-plugins home/.claude/projects].each { |path| FileUtils.mkdir_p(path) }
      read_only = with_env("HOME" => "#{dir}/home") { with_bwrap(overlay: true) { read_only_binds } }
      assert_equal([true, false], %w[new-plugins projects].map { |name| read_only.include?(claude_path(dir, name)) })
    end
  end

  def claude_path(dir, name) = "#{dir}/home/.claude/#{name}"

  def read_only_binds
    Sandbox.wrap(CMD, harness("claude")).each_cons(3).select { |flag, _, _| flag == "--ro-bind" }.map { _2 }
  end

  def test_the_profile_protects_the_harness_config_in_a_worktree
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      FileUtils.mkdir_p(".maf/worktrees/w1/.claude")
      assert_includes denials(harness("claude")), subpath(dir, ".maf/worktrees/w1/.claude/settings.json")
    end
  end

  def test_a_star_in_a_state_path_matches_one_part_of_a_name
    rule = Sandbox::Seatbelt.regex("/h/.codex/*.sqlite*")
    assert_equal '(regex #"^/h/\\.codex/[^/]*\\.sqlite[^/]*(/|$)")', rule
  end
end
