#!/usr/bin/env ruby
# frozen_string_literal: true

# test/pty_relay_test.rb - tests for lib/maf/setup_agent/pty_relay.rb.
#
# Run: ruby test/pty_relay_test.rb
require_relative "harnesses/helper"
require_relative "../lib/maf/setup_agent/pty_relay"
require "stringio"
require "timeout"

class PtyRelayTest < Minitest::Test
  Relay = Maf::SetupAgent::PtyRelay

  def relay(script, input = "")
    stdin = $stdin
    $stdin = StringIO.new(input)
    capture_io { @status = Relay.new(["sh", "-c", script]).run }.first.then { |out| [@status, out] }
  ensure
    $stdin = stdin
  end

  def test_the_relay_returns_the_output_and_the_exit_status
    status, output = relay("echo hello; exit 3")
    assert_equal 3, status
    assert_includes output, "hello"
  end

  def test_the_command_gets_the_end_of_the_input
    %W[task\n task].each do |input|
      status, output = Timeout.timeout(10) { relay("cat; echo done", input) }
      assert_equal [0, true], [status, output.include?("done")]
    end
  end

  def test_the_command_gets_its_own_terminal
    _status, output = relay("tty")
    assert_match %r{/dev/(pts/|tty)}, output
  end

  def test_the_relay_passes_term_to_the_command
    reader, writer = IO.pipe
    pid = Process.spawn(*RELAY_ARGS, "sh", "-c", TRAP, in: File::NULL, out: writer).tap { writer.close }
    sleep(1) && Process.kill("TERM", pid)
    assert_equal [7, true], [Process.wait2(pid).last.exitstatus, reader.read.include?("got-term")]
  end

  TRAP = 'trap "echo got-term; exit 7" TERM; while :; do sleep 0.1; done'
  RELAY_ARGS = [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rmaf/setup_agent/pty_relay",
                "-e", "exit Maf::SetupAgent::PtyRelay.new(ARGV).run"].freeze

  def test_an_injection_does_not_reach_the_terminal_of_the_user
    skip "needs macOS, script, and perl" unless RUBY_PLATFORM.include?("darwin") && system("which perl > /dev/null")
    assert_equal "[Z]", outer_line(INJECT)
    assert_equal "[]", outer_line("#{RELAY} #{INJECT}")
  end

  INJECT = %(perl -e 'for (split //, "Z\n") { my $c = $_; ioctl(STDIN, 0x80017472, $c) }')
  RELAY = "ruby -I#{File.expand_path("../lib", __dir__)} -rmaf/setup_agent/pty_relay " \
          "-e 'exit Maf::SetupAgent::PtyRelay.new(ARGV).run'".freeze

  def outer_line(command)
    script = "#{command}; read -r -t 1 x; echo \"[$x]\""
    out = IO.popen(["sh", "-c", "sleep 3 | script -q /dev/null bash -c #{script.shellescape}"], &:read)
    out.delete("\r").lines.last.to_s.strip
  end
end
