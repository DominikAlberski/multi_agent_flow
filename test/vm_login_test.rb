#!/usr/bin/env ruby
# frozen_string_literal: true

# test/vm_login_test.rb - tests for maf vm login (lib/maf/vm/login.rb).
#
# Run: ruby test/vm_login_test.rb
require_relative "harnesses/helper"
require "stringio"

class VmLoginTest < Minitest::Test
  include HarnessTestHelpers

  Credential = Maf::Shared::Harness::VmCredential
  FakeHarness = Struct.new(:name, :vm_credentials, :vm_login_hint)

  def with_fake_vm
    in_tmpdir do |dir|
      fake_limactl(dir)
      with_env("PATH" => "#{dir}/bin:#{ENV.fetch("PATH")}") { yield File.join(dir, "vm_home") }
    end
  end

  def fake_limactl(dir)
    write("bin/limactl", "#!/bin/sh\nshift 4\nexec env HOME=#{dir}/vm_home \"$@\"\n")
    File.chmod(0o755, "bin/limactl")
    FileUtils.mkdir_p("vm_home")
  end

  def login(harness, mode, answers = "")
    output = StringIO.new
    Maf::Vm::Login.new("maf-x", [harness], mode, Maf::Prompt.new(StringIO.new(answers), output)).run
    output.string
  end

  def codex(text = "token") = FakeHarness.new("codex", [Credential.new(".codex/auth.json") { text }], "log in")

  def test_a_yes_copies_the_login_for_the_user_only
    with_fake_vm do |home|
      assert_includes login(codex, :ask, "y\n"), "copied  codex login"
      assert_equal "token", File.read(File.join(home, ".codex/auth.json"))
      assert_equal 0o600, File.stat(File.join(home, ".codex/auth.json")).mode & 0o777
    end
  end

  def test_an_old_readable_login_file_becomes_private
    with_fake_vm do |home|
      path = File.join(home, ".codex/auth.json").tap { |file| write(file, "old") && File.chmod(0o644, file) }
      login(codex, :all)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_a_no_copies_nothing_and_shows_the_hint
    with_fake_vm do |home|
      assert_includes login(codex, :ask, "n\n"), "codex: Log in in the VM: log in"
      refute File.exist?(File.join(home, ".codex/auth.json"))
    end
  end

  def test_copy_logins_asks_no_question
    with_fake_vm { |home| login(codex, :all) && assert(File.exist?(File.join(home, ".codex/auth.json"))) }
  end

  def test_no_copy_logins_asks_no_question
    with_fake_vm { assert_equal "codex: Log in in the VM: log in\n", login(codex, :none) }
  end

  def test_a_harness_without_a_copyable_login_gets_only_the_hint
    cursor = FakeHarness.new("cursor", [], "agent login")
    with_fake_vm { assert_equal "cursor: Log in in the VM: agent login\n", login(cursor, :ask, "y\n") }
  end

  def test_a_missing_host_login_gets_the_hint
    with_fake_vm { assert_includes login(codex(nil), :ask, "y\n"), "maf found no login on this computer" }
  end

  def test_a_file_credential_reads_the_host_file
    in_tmpdir do |dir|
      write("auth.json", "secret")
      assert_equal "secret", Credential.file(File.join(dir, "auth.json"), "x").read
      assert_nil Credential.file(File.join(dir, "missing.json"), "x").read
    end
  end

  def test_each_harness_copies_into_its_linux_login_path
    paths = %w[claude codex opencode hermes].to_h { |id| [id, harness(id).vm_credentials.map(&:dest)] }
    assert_equal({ "claude" => [".claude/.credentials.json"], "codex" => [".codex/auth.json"],
                   "opencode" => [".local/share/opencode/auth.json"], "hermes" => [".hermes/.env"] }, paths)
  end
end
