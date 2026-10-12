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

  def with_bwrap(overlay:)
    originals = { available?: true, overlay?: overlay }.to_h { |name, value| [name, stub(name, value)] }
    yield
  ensure
    originals.each { |name, method| Sandbox::Bwrap.define_singleton_method(name, method) }
  end

  def stub(name, value) = Sandbox::Bwrap.method(name).tap { Sandbox::Bwrap.define_singleton_method(name) { value } }

  # The home folder is inside the project folder, so the test touches no real harness folder.
  def bwrap_command(overlay:, &block)
    in_project("sandbox" => { "mode" => "bwrap" }) do |dir|
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

  def test_bwrap_puts_a_temporary_overlay_on_the_home_folder
    bwrap_command(overlay: true) { |cmd, home| assert_includes cmd.each_cons(2).to_a, ["--tmp-overlay", home] }
    bwrap_command(overlay: false) { |cmd, _home| refute_includes cmd, "--tmp-overlay" }
  end

  # With the overlay, the write succeeds in the sandbox, but the file is gone after the run.
  def test_bwrap_keeps_a_write_outside_the_project
    skip "bubblewrap runs on Linux only" unless RUBY_PLATFORM.include?("linux") && Sandbox::Bwrap.available?
    in_project("sandbox" => { "mode" => "bwrap" }) do |dir|
      assert touch_sandboxed(File.join(dir, "in"))
      Dir.mktmpdir(nil, Dir.home) { |outside| refute written_outside?(File.join(outside, "out")) }
    end
  end

  def written_outside?(path) = touch_sandboxed(path) && File.exist?(path)
end
