#!/usr/bin/env ruby
# frozen_string_literal: true

# test/vm_owner_test.rb - maf vm acts only on the VM that mounts the project.
#
# Run: ruby test/vm_owner_test.rb
require_relative "harnesses/helper"

class VmOwnerTest < Minitest::Test
  include HarnessTestHelpers

  FAKE = <<~SH
    #!/bin/sh
    if [ "$1" = list ]; then printf '%s' "$FAKE_MOUNTS"; exit 0; fi
    echo "$@" >> "$FAKE_LOG"
  SH

  def with_vm(mounts)
    in_tmpdir do |dir|
      write("bin/limactl", FAKE) && File.chmod(0o755, "bin/limactl")
      env = { "PATH" => "#{dir}/bin:#{ENV.fetch("PATH")}", "FAKE_MOUNTS" => mounts.call(dir), "FAKE_LOG" => "log" }
      with_env(env) { yield dir }
    end
  end

  def run_vm(dir, *argv) = capture_io { Maf::Vm.new(argv, dir).run }
  def calls = File.exist?("log") ? File.read("log") : ""

  def test_maf_deletes_the_vm_of_the_project
    with_vm(->(dir) { JSON.generate([{ "location" => dir }]) }) do |dir|
      run_vm(dir, "delete")
      assert_match(/\Adelete --force maf-/, calls)
    end
  end

  def test_maf_does_not_touch_the_vm_of_another_project
    with_vm(->(_dir) { JSON.generate([{ "location" => "/other/app" }]) }) do |dir|
      assert_raises(SystemExit) { run_vm(dir, "delete") }
      assert_empty calls
    end
  end

  def test_the_vm_shell_loads_the_project_environment
    in_tmpdir do |dir|
      cmd = Maf::Vm.new(%w[shell coord status], dir).shell_command
      assert_equal %w[bash coord status], cmd.last(3)
      assert_includes cmd[-4], ". ./.maf/env.sh"
    end
  end

  def test_maf_does_not_touch_a_vm_without_mounts
    with_vm(->(_dir) { "null" }) do |dir|
      assert_raises(SystemExit) { run_vm(dir, "delete") }
      assert_empty calls
    end
  end

  def test_maf_stops_when_the_project_has_no_vm
    with_vm(->(_dir) { "" }) { |dir| assert_raises(SystemExit) { run_vm(dir, "stop") } }
  end
end
