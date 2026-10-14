# frozen_string_literal: true

require "pty"
require "io/console"

module Maf
  module SetupAgent
    # PtyRelay runs a command on its own pseudo terminal and copies the input and the output.
    class PtyRelay
      CHUNK = 4096
      DRAIN = 0.5
      SIGNALS = %w[TERM HUP INT].freeze
      EOF = "\x04"

      def initialize(cmd) = @cmd = cmd

      def run
        output, input, pid = PTY.spawn(*@cmd)
        SIGNALS.each { |name| Signal.trap(name) { pass(name, pid) } }
        relay(output, input, Process.detach(pid))
      ensure
        [output, input].compact.each(&:close)
      end

      private

      def relay(output, input, waiter)
        resize(input) && Signal.trap("WINCH") { resize(input) }
        copiers = [Thread.new { copy_input(input) }, Thread.new { copy(output, $stdout) }]
        raw { waiter.join }
        stop(copiers)
        waiter.value.exitstatus || 1
      end

      def stop(copiers)
        copiers.last.join(DRAIN)
        copiers.each(&:kill)
      end

      def copy(from, to)
        loop { to.write(from.readpartial(CHUNK)) && to.flush }
      rescue IOError, Errno::EIO
        nil
      end

      # The end of the input is no end on a terminal, so the command gets ^D. Else `echo task | maf start` waits.
      # After a line without a newline, the first ^D only sends the line, so the command gets a second one.
      def copy_input(input)
        last = send_input(input)
        input.write(last.end_with?("\n") ? EOF : EOF * 2)
      rescue IOError, Errno::EIO
        nil
      end

      def send_input(input)
        last = "\n"
        loop { input.write(last = $stdin.readpartial(CHUNK)) && input.flush }
      rescue EOFError
        last
      end

      def pass(name, pid)
        Process.kill(name, pid)
      rescue Errno::ESRCH
        nil
      end

      def raw(&block) = $stdin.tty? ? $stdin.raw(&block) : yield

      def resize(input)
        $stdout.tty? && (input.winsize = $stdout.winsize)
      end
    end
  end
end
