# frozen_string_literal: true

require_relative "../shared/sandbox"

module Maf
  module SetupAgent
    # Launcher replaces this process with the interactive session of a harness.
    # The harness file builds the command (Maf::Shared::Harnesses).
    module Launcher
      def self.launch(harness, role, model)
        ENV.update(harness.launch_env)
        warn "maf: sandbox: #{Maf::Shared::Sandbox.describe(harness)}" unless Maf::Shared::Sandbox.mode == "off"
        exec_or_die(Maf::Shared::Sandbox.wrap(harness.launch(role, model), harness))
      end

      def self.exec_or_die(cmd)
        Kernel.exec(*cmd)
      rescue Errno::ENOENT
        abort "setup_agent: '#{cmd.first}' not found on PATH."
      end
    end
  end
end
