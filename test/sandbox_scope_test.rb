#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_scope_test.rb - tests for the scope of lib/maf/shared/sandbox.rb.
#
# Run: ruby test/sandbox_scope_test.rb
require_relative "sandbox_helper"

class SandboxScopeTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def test_an_interactive_session_runs_on_the_host_by_default
    in_project("sandbox" => { "mode" => "seatbelt" }) { assert_equal "off", Sandbox.interactive_mode }
  end

  def test_the_scope_all_puts_an_interactive_session_in_the_sandbox
    in_project("sandbox" => { "mode" => "seatbelt", "scope" => "all" }) do
      assert_equal "seatbelt", Sandbox.interactive_mode
    end
  end

  def test_the_scope_does_not_change_a_dispatched_run
    in_project("sandbox" => { "mode" => "seatbelt", "scope" => "dispatch" }) do
      assert_equal "/usr/bin/sandbox-exec", Sandbox.wrap(CMD, harness("claude")).first
    end
  end

  def test_an_unknown_scope_stops_maf
    in_project("sandbox" => { "mode" => "seatbelt", "scope" => "never" }) do
      assert_raises(SystemExit) { capture_io { Sandbox.interactive_mode } }
    end
  end
end
