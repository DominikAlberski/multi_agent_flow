# frozen_string_literal: true

require_relative "../shared/sandbox"
require_relative "pty_relay"

module Maf
  module SetupAgent
    # Launcher replaces this process with the interactive session of a harness.
    # The harness file builds the command (Maf::Shared::Harnesses).
    # The session runs in the sandbox only when .maf/sandbox.json sets "scope": "all".
    module Launcher
      def self.launch(harness, role, model, effort = nil)
        ENV.update(harness.launch_env)
        return exec_or_die(harness.launch(role, model, effort)) if Maf::Shared::Sandbox.interactive_mode == "off"

        warn "maf: sandbox: #{Maf::Shared::Sandbox.describe(harness)}"
        exit Maf::Shared::Sandbox.keeping_links(harness) { relay_or_die(sandboxed(harness, role, model, effort)) }
      end

      def self.sandboxed(harness, role, model, effort)
        Maf::Shared::Sandbox.wrap(harness.launch(role, model, effort), harness)
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
