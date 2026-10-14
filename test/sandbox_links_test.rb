#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_links_test.rb - tests for lib/maf/shared/sandbox/links.rb.
#
# Run: ruby test/sandbox_links_test.rb
require_relative "sandbox_helper"

class SandboxLinksTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  TASKRC = ".maf/coordination/taskrc"

  def test_a_bwrap_run_puts_back_a_protected_link
    in_project("sandbox" => { "mode" => "bwrap" }) do |dir|
      link_taskrc(dir)
      _, err = capture_io { with_bwrap(overlay: true) { Sandbox.keeping_links(harness("claude")) { replace(TASKRC) } } }
      assert_equal ["#{dir}/dotfiles/taskrc", "put it back"], [File.readlink(TASKRC), err[/put it back/]]
    end
  end

  def test_an_unchanged_link_stays_quiet
    Dir.mktmpdir do |dir|
      File.symlink("/etc/hosts", "#{dir}/link")
      assert_output("", "") { Sandbox::Links.restore(Sandbox::Links.record(["#{dir}/link"])) }
    end
  end

  def link_taskrc(dir)
    write("dotfiles/taskrc", "")
    FileUtils.mkdir_p(".maf/coordination")
    File.symlink("#{dir}/dotfiles/taskrc", TASKRC)
  end

  def replace(path) = File.unlink(path) && File.write(path, "agent")
end
