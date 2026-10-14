#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_bwrap_test.rb - tests for lib/maf/shared/sandbox/bwrap.rb.
#
# Run: ruby test/sandbox_bwrap_test.rb
require_relative "sandbox_helper"

class SandboxBwrapTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def test_auto_picks_the_sandbox_of_the_os
    in_project("sandbox" => { "mode" => "auto" }) do
      with_bwrap(overlay: true) { assert_equal RUBY_PLATFORM.include?("darwin") ? "seatbelt" : "bwrap", Sandbox.mode }
    end
  end

  def test_a_run_inside_the_sandbox_is_not_wrapped_again
    in_project("sandbox" => { "mode" => "bwrap" }) do
      with_bwrap(overlay: true, inside: true) { assert_equal CMD, Sandbox.wrap(CMD, harness("claude")) }
    end
  end

  def bwrap_command(overlay:, write: [], &block)
    in_project("sandbox" => { "mode" => "bwrap", "write" => write }) do |dir|
      home = File.join(dir, "home")
      with_env("HOME" => home) { with_bwrap(overlay: overlay) { block.call(claude_command, home) } }
    end
  end

  def claude_command = Sandbox.wrap(CMD, harness("claude"))

  def binds(cmd) = cmd.each_cons(3).select { |flag, _, _| flag == "--bind" }.map { |_, path, _| path }

  def test_bwrap_binds_the_project_and_the_harness_folder
    bwrap_command(overlay: true) do |cmd, home|
      assert_equal %w[bwrap --ro-bind / /], cmd.first(4)
      assert_empty [File.dirname(home), File.join(home, ".claude")] - binds(cmd)
      assert_equal ["--", *CMD], cmd.last(4)
    end
  end

  def test_bwrap_puts_a_temporary_overlay_on_the_home_folder_and_sets_the_marker
    bwrap_command(overlay: true) do |cmd, home|
      assert_empty [["--tmp-overlay", home], ["--setenv", "MAF_BWRAP"]] - cmd.each_cons(2).to_a
    end
  end

  def test_bubblewrap_without_the_overlay_stops_maf
    assert_raises(SystemExit) { capture_io { bwrap_command(overlay: false) { flunk "maf ran the agent" } } }
  end

  def pairs_after(cmd, flag) = cmd.each_cons(3).select { |f, _, _| f == flag }.map { |_, path, _| path }

  def test_bwrap_protects_the_policy_and_keeps_its_folder_in_place
    bwrap_command(overlay: true) do |cmd, home|
      project = File.dirname(home)
      assert_includes pairs_after(cmd, "--ro-bind"), File.join(project, ".maf", "sandbox.json")
      assert_includes pairs_after(cmd, "--bind"), File.join(project, ".maf")
    end
  end

  def test_bwrap_creates_and_protects_the_taskwarrior_hooks
    bwrap_command(overlay: true) do |cmd, home|
      hooks = File.join(File.dirname(home), ".maf", "coordination", "taskdata", "hooks")
      assert File.directory?(hooks)
      assert_includes pairs_after(cmd, "--ro-bind"), hooks
    end
  end

  def test_bwrap_creates_the_claude_state_file
    bwrap_command(overlay: true) do |cmd, home|
      assert_equal "{}\n", File.read(File.join(home, ".claude.json"))
      assert_includes pairs_after(cmd, "--bind"), File.join(home, ".claude.json")
    end
  end

  def test_bwrap_creates_the_missing_config_of_the_harness
    bwrap_command(overlay: true) do |cmd, home|
      settings, skills, memory = %w[settings.json skills CLAUDE.md].map { |name| File.join(home, ".claude", name) }
      assert_equal ["{}\n", true, false], [File.read(settings), File.directory?(skills), File.exist?(memory)]
      assert_includes pairs_after(cmd, "--ro-bind"), settings
    end
  end

  def test_bwrap_gives_the_agent_a_private_tmp_and_shared_memory
    bwrap_command(overlay: true) do |cmd, _home|
      assert_empty [["--tmpfs", "/tmp"], ["--tmpfs", "/dev/shm"]] - cmd.each_cons(2).to_a
      refute_includes binds(cmd), "/tmp"
    end
  end

  def test_bwrap_binds_a_file_of_the_write_list_and_the_claude_state_file
    bwrap_command(overlay: true, write: ["~/notes.txt"]) do |_cmd, home|
      files = [File.join(home, "notes.txt"), File.join(home, ".claude.json")].each { |file| write(file, "{}") }
      assert_empty files - binds(claude_command)
    end
  end

  def test_bwrap_keeps_a_write_outside_the_project
    skip "bubblewrap runs on Linux only" unless RUBY_PLATFORM.include?("linux") && Sandbox::Bwrap.available?
    in_project("sandbox" => { "mode" => "bwrap" }) do |dir|
      assert touch_sandboxed(File.join(dir, "in"))
      Dir.mktmpdir(nil, Dir.home) { |outside| refute written_outside?(File.join(outside, "out")) }
    end
  end

  def written_outside?(path) = touch_sandboxed(path) && File.exist?(path)

  def test_bwrap_hides_the_user_service_manager
    skip "needs Linux, bubblewrap, and systemd --user" unless user_systemd?
    in_project("sandbox" => { "mode" => "bwrap" }) do
      Dir.mktmpdir(nil, Dir.home) { |outside| refute escaped_via_systemd?(File.join(outside, "out")) }
    end
  end

  def escaped_via_systemd?(path)
    system(*Sandbox.wrap(["systemd-run", "--user", "--wait", "-q", "touch", path], harness("claude")),
           out: File::NULL, err: File::NULL)
    File.exist?(path)
  end

  def user_systemd?
    RUBY_PLATFORM.include?("linux") && Sandbox::Bwrap.available? && File.socket?("/run/user/#{Process.uid}/bus")
  end
end
