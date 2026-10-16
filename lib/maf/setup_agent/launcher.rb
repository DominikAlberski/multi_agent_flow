# frozen_string_literal: true

require_relative "../shared/sandbox"
require_relative "pty_relay"

module Maf
  module SetupAgent
    # Launcher replaces this process with the interactive session of a harness.
    # The harness file builds the command (Maf::Shared::Harnesses).
    module Launcher
      def self.launch(harness, role, model, effort = nil)
        ENV.update(harness.launch_env)
        cmd = harness.launch(role, model, effort)
        return exec_or_die(cmd) if Maf::Shared::Sandbox.mode == "off"

        warn "maf: sandbox: #{Maf::Shared::Sandbox.describe(harness)}"
        exit Maf::Shared::Sandbox.keeping_links(harness) { relay_or_die(Maf::Shared::Sandbox.wrap(cmd, harness)) }
      end

      def self.exec_or_die(cmd)
        Kernel.exec(*cmd)
      rescue Errno::ENOENT
        abort "setup_agent: '#{cmd.first}' not found on PATH."
      end

      def self.relay_or_die(cmd)
        PtyRelay.new(cmd).run
      rescue Errno::ENOENT
        abort "setup_agent: '#{cmd.first}' not found on PATH."
      end
    end
  end
end
