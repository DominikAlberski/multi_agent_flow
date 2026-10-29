#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_sockets_test.rb - the macOS sandbox allows the PostgreSQL socket
# in /tmp, but it blocks the other sockets there.
#
# Run: ruby test/sandbox_sockets_test.rb
require_relative "sandbox_helper"

class SandboxSocketsTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  POSTGRES = "/tmp/.s.PGSQL.#{40_000 + (Process.pid % 20_000)}".freeze
  OTHER = "/tmp/maf-socket-#{Process.pid}".freeze

  def setup
    skip "sandbox-exec is macOS only" unless RUBY_PLATFORM.include?("darwin") && Sandbox::Seatbelt.available?
  end

  def teardown = FileUtils.rm_f([POSTGRES, OTHER])

  def test_the_sandbox_allows_the_postgres_socket_in_tmp
    in_project("sandbox" => { "mode" => "seatbelt" }) { assert connects?(POSTGRES) }
  end

  def test_the_sandbox_blocks_another_socket_in_tmp
    in_project("sandbox" => { "mode" => "seatbelt" }) { refute connects?(OTHER) }
  end
end
