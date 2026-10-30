#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_seatbelt_profile_test.rb - the macOS sandbox profile for the
# tools of a project: launch_services folders and globs, the tag of a denial,
# and the libpq environment.
#
# Run: ruby test/sandbox_seatbelt_profile_test.rb
require_relative "sandbox_helper"

class SandboxSeatbeltProfileTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def setup
    skip "sandbox-exec is macOS only" unless RUBY_PLATFORM.include?("darwin") && Sandbox::Seatbelt.available?
  end

  # Regression: Selenium Manager keeps chromedriver in a folder per version.
  # A folder entry allowed no program, because it was not an app.
  def test_a_launch_services_folder_allows_each_program_in_it
    in_drivers(%w[156]) do |outside, drivers|
      write_file(File.join(outside, "LICENSE"), "text", 0o644)
      assert_includes launch_services_rule(outside), process_rule(drivers.first)
      refute_includes launch_services_rule(outside), "LICENSE"
    end
  end

  def test_a_launch_services_glob_matches_each_version
    in_drivers(%w[155 156]) do |outside, drivers|
      rule = launch_services_rule(File.join(outside, "*", "chromedriver"))
      drivers.each { |driver| assert_includes rule, process_rule(driver) }
    end
  end

  # Regression: a folder entry above the project allowed the programs that the agent can change.
  def test_a_launch_services_folder_that_holds_the_project_is_refused
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      write(".maf/sandbox.json", JSON.generate("mode" => "seatbelt", "launch_services" => [File.dirname(dir)]))
      error = assert_raises(SystemExit) { capture_io { wrapped("true") } }
      refute error.success?
    end
  end

  def test_a_launch_services_path_with_brackets_is_no_glob
    Dir.mktmpdir("maf-app-", Dir.home) do |outside|
      driver = File.join(outside, "Foo [Beta]", "chromedriver")
      write_file(driver, "#!/bin/sh\n", 0o755)
      assert_includes launch_services_rule(File.dirname(driver)), process_rule(driver)
    end
  end

  def in_drivers(versions)
    Dir.mktmpdir("maf-app-", Dir.home) do |outside|
      drivers = versions.map { |version| File.join(outside, version, "chromedriver") }
      drivers.each { |driver| write_file(driver, "#!/bin/sh\n", 0o755) }
      yield outside, drivers
    end
  end

  def process_rule(path) = "(process-path \"#{File.realpath(path)}\")"

  def test_a_launch_services_denial_carries_the_tag_of_the_project
    in_project("sandbox" => { "mode" => "seatbelt" }) do |dir|
      assert_includes wrapped("true")[2], "(with message \"#{Sandbox::Seatbelt.tag(dir)}\")"
    end
  end

  # Regression: libpq tries GSSAPI encryption on a TCP connection, and the
  # Kerberos framework of macOS crashes in a forked child (parallel tests).
  def test_libpq_does_not_try_gssapi_encryption
    in_project("sandbox" => { "mode" => "seatbelt" }) do
      with_env("PGGSSENCMODE" => nil) { assert sandboxed('test "$PGGSSENCMODE" = disable') }
      with_env("PGGSSENCMODE" => "prefer") { assert sandboxed('test "$PGGSSENCMODE" = prefer') }
    end
  end

  def launch_services_rule(app)
    in_project("sandbox" => { "mode" => "seatbelt", "launch_services" => [app] }) do
      wrapped("true")[2][/\(allow mach-lookup .*\z/m]
    end
  end

  def write_file(path, text, mode)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.chmod(mode, path)
  end
end
