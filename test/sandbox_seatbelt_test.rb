#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_seatbelt_test.rb - the macOS sandbox blocks a write outside the
# project, a host socket, and LaunchServices, but it keeps DNS.
#
# Run: ruby test/sandbox_seatbelt_test.rb
require_relative "sandbox_helper"

class SandboxSeatbeltTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def setup
    skip "sandbox-exec is macOS only" unless RUBY_PLATFORM.include?("darwin") && Sandbox::Seatbelt.available?
  end

  def test_the_sandbox_blocks_a_write_outside_the_project
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      assert touch_sandboxed(File.join(dir, "in"))
      Dir.mktmpdir(nil, Dir.home) { |outside| refute touch_sandboxed(File.join(outside, "out")) }
    end
  end

  def test_a_run_does_not_take_the_temporary_folder_of_another_project
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      cmd = with_env("TMPDIR" => "/tmp/maf-sandbox-other/") { Sandbox.wrap(CMD, harness("claude")) }
      assert_includes cmd, "TMPDIR=#{Sandbox::Seatbelt.project_tmp(dir)}/"
    end
  end

  def test_the_sandbox_blocks_a_socket_outside_the_project
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      assert connects?(File.join(dir, "s"))
      Dir.mktmpdir(nil, Dir.home) { |outside| refute connects?(File.join(outside, "s")) }
    end
  end

  def test_the_sandbox_blocks_open
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      Dir.mktmpdir("maf-open-", "/tmp") { |dir| refute opens_app?(dir) }
    end
  end

  def test_a_launch_services_app_gets_only_launchservicesd
    Dir.mktmpdir("maf-app-", Dir.home) do |outside|
      rule = launch_services_rule(probe_app(outside))
      assert_includes rule, '(global-name "com.apple.coreservices.launchservicesd")'
      assert_includes rule, "(process-path \"#{File.realpath(outside)}/Probe.app/Contents/MacOS/Probe\")"
    end
  end

  def launch_services_rule(app)
    in_project("sandbox" => { "mode" => "seatbelt", "launch_services" => [app] }) do
      wrapped("true")[2][/\(allow mach-lookup .*\z/m]
    end
  end

  def test_open_stays_blocked_with_a_launch_services_app
    Dir.mktmpdir("maf-open-", Dir.home) do |dir|
      in_project("sandbox" => { "mode" => "seatbelt", "launch_services" => [File.join(dir, "Probe.app")] }) do
        refute opens_app?(dir)
      end
    end
  end

  def test_a_launch_services_app_in_a_writable_folder_is_refused
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write(".maf/sandbox.json", JSON.generate("mode" => "seatbelt", "launch_services" => [probe_app(dir)]))
      error = assert_raises(SystemExit) { capture_io { wrapped("true") } }
      refute error.success?
    end
  end

  def opens_app?(dir)
    system(*Sandbox.wrap(["open", "-g", "-j", probe_app(dir)], harness("claude")), err: File::NULL)
    sleep 3
    File.exist?(File.join(dir, "marker"))
  end

  def probe_app(dir)
    app = File.join(dir, "Probe.app")
    write_file(File.join(app, "Contents/MacOS/Probe"), "#!/bin/sh\ntouch #{dir}/marker\n", 0o755)
    write_file(File.join(app, "Contents/Info.plist"), PLIST, 0o644)
    app
  end

  def write_file(path, text, mode)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.chmod(mode, path)
  end

  PLIST = '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string>' \
          "<key>CFBundleIdentifier</key><string>maf.test.probe</string>" \
          "<key>CFBundlePackageType</key><string>APPL</string></dict></plist>"

  # The ruler pasteboard keeps the clipboard of the user. Without the map database of
  # LaunchServices, pbcopy wrote the text with a type that pbpaste does not read.
  def test_a_copy_in_the_sandbox_pastes
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      text = "maf-#{Process.pid}"
      assert sandboxed("printf #{text} | pbcopy -pboard ruler")
      assert_equal text, IO.popen(%w[pbpaste -pboard ruler], &:read)
    end
  end

  def test_a_sandboxed_command_sees_the_marker
    in_project("sandbox" => { "mode" => "seatbelt" }) { assert sandboxed('test "$MAF_SEATBELT" = 1') }
  end

  def test_a_sandboxed_process_cannot_start_a_second_sandbox
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      error = assert_raises(SystemExit) { with_env("MAF_SEATBELT" => "1") { capture_io { wrapped("true") } } }
      refute error.success?
    end
  end

  def test_the_sandbox_keeps_dns
    skip "no network" unless system(*LOOKUP, err: File::NULL)
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      assert system(*Sandbox.wrap(LOOKUP, harness("claude")), err: File::NULL)
    end
  end

  LOOKUP = [RbConfig.ruby, "-rsocket", "-e", 'Addrinfo.getaddrinfo("github.com", 443)'].freeze
end
