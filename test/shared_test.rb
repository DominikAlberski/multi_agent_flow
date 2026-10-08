#!/usr/bin/env ruby
# frozen_string_literal: true

# test/shared_test.rb - tests for lib/maf/shared/, the library that the maf CLI
# and the installed scripts share.
#
# Run: ruby test/shared_test.rb
require "minitest/autorun"
require "rbconfig"
require "open3"
require_relative "../lib/maf/bootstrap"
require_relative "../lib/maf/shared/processes"

SHARED_FILES = Dir[File.expand_path("../lib/maf/shared/*.rb", __dir__)]

# An installed script loads one shared file with no load path and no gems.
class SharedLoadTest < Minitest::Test
  def test_each_file_loads_alone_with_the_stdlib
    SHARED_FILES.each do |file|
      out, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", "-e", "require ARGV[0]", file)
      assert status.success?, "#{File.basename(file)}: #{out}"
    end
  end

  # The installer and the uninstaller know a shared file by this signature.
  def test_each_file_carries_the_signature
    SHARED_FILES.each { |file| assert_includes File.read(file), Bootstrap::SHARED_SIGNATURE, file }
  end
end

class ProcessesTest < Minitest::Test
  Processes = Maf::Shared::Processes

  def test_the_current_process_is_alive
    assert Processes.alive?(Process.pid)
  end

  def test_a_pid_that_is_not_positive_is_not_alive
    [0, -1, nil, ""].each { |pid| refute Processes.alive?(pid), pid.inspect }
  end

  def test_an_ended_process_is_not_alive
    pid = Process.spawn(RbConfig.ruby, "-e", "exit")
    Process.wait(pid)

    refute Processes.alive?(pid)
    assert_equal "", Processes.started_at(pid)
  end

  # pid 1 belongs to root. kill(0) on it raises EPERM for other users.
  def test_a_process_of_another_user_is_alive
    skip "runs as root" if Process.uid.zero?

    assert Processes.alive?(1)
  end

  def started_in(zone)
    old = ENV.fetch("TZ", nil)
    ENV["TZ"] = zone
    Processes.started_at(Process.pid)
  ensure
    ENV["TZ"] = old
  end

  def test_the_start_time_does_not_depend_on_the_time_zone
    tokyo = started_in("Asia/Tokyo")

    refute_empty tokyo
    assert_equal tokyo, started_in("UTC")
  end
end
