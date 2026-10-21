#!/usr/bin/env ruby
# frozen_string_literal: true

# test/dispatcher_sandbox_test.rb - tests for the sandbox parts of assets/dispatcher.
#
# Run: ruby test/dispatcher_sandbox_test.rb
require "minitest/autorun"
require_relative "board_guard"
require "tmpdir"
require "fileutils"
require "json"

load File.expand_path("../assets/coord", __dir__)
load File.expand_path("../assets/dispatcher", __dir__)

class DispatcherSandboxTest < Minitest::Test
  Sandbox = Maf::Shared::Sandbox

  def config = Dispatcher::Config.new(role: "backend-developer", harness: "hermes", timeout: 5, coord_dir: "/tmp")

  def test_a_run_starts_in_its_own_session
    result = Dispatcher::Spawn.run([RbConfig.ruby, "-e", "print Process.getsid == Process.pid"], env: {}, timeout: 5)
    assert_equal "true", result.output
  end

  def test_a_missing_command_is_a_failure_with_its_error
    result = Dispatcher::Spawn.run(["no-such-agent-binary"], env: {}, timeout: 5)
    refute result.success
    assert_includes result.output, "no-such-agent-binary"
  end

  def test_a_bad_command_is_a_failure_with_its_error
    result = Dispatcher::Spawn.run(["sh", nil], env: {}, timeout: 5)
    assert_equal [false, true], [result.success, result.output.include?("nil")]
  end

  def test_the_verify_command_runs_in_the_sandbox
    calls = []
    with_wrap(->(cmd, harness, **) { (calls << [cmd, harness]) && cmd }) { Dispatcher::Verify.sandboxed("true", config) }
    assert_equal [[%w[sh -c true], Dispatcher::Harness::Generic]], calls
  end

  def test_a_dispatcher_in_a_sandbox_stops_with_the_reason
    Dir.mktmpdir do |dir|
      log = File.join(dir, "dispatcher.log")
      error = with_log(log) { nested { assert_raises(SystemExit) { Dispatcher.refuse_nested } } }
      assert_equal [false, true], [error.success?, File.read(log).include?("maf start")]
    end
  end

  def nested
    original = Sandbox.method(:nested?)
    Sandbox.define_singleton_method(:nested?) { |*| true }
    yield
  ensure
    Sandbox.define_singleton_method(:nested?, original)
  end

  def with_log(path)
    saved = ENV.fetch("DISPATCHER_LOG", nil)
    ENV["DISPATCHER_LOG"] = path
    yield
  ensure
    ENV["DISPATCHER_LOG"] = saved
  end

  def test_the_sandbox_takes_the_generic_harness
    Dir.mktmpdir do |dir|
      paths = Sandbox::Paths.new([Dispatcher::Harness::Generic], dir, nil, [])
      assert_equal [[], []], [paths.placeholders, paths.state]
      assert_kind_of Array, paths.protected
    end
  end

  def test_the_generic_harness_has_each_method_of_a_harness
    missing = Maf::Shared::Harness::Run.instance_methods.reject { |name| Dispatcher::Harness::Generic.respond_to?(name) }
    assert_empty missing
  end

  def test_the_dispatcher_runs_the_coord_of_the_main_checkout
    Dir.mktmpdir do |dir|
      worktree_with_coord(dir)
      Dir.chdir(File.join(dir, "sub")) { assert_equal File.realpath(dir), coord_root }
    end
  end

  def worktree_with_coord(dir)
    system("git", "init", "-q", dir)
    coord = File.join(dir, "sub/.maf/bin/coord")
    FileUtils.mkdir_p(File.dirname(coord))
    File.write(coord, "") && File.chmod(0o755, coord)
  end

  def coord_root = File.realpath(File.expand_path("../../..", Dispatcher::CoordCall.command.last))

  def with_wrap(fake)
    original = Sandbox.method(:wrap)
    Sandbox.define_singleton_method(:wrap, &fake)
    yield
  ensure
    Sandbox.define_singleton_method(:wrap, original)
  end
end
