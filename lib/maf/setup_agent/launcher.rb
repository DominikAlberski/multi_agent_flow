# frozen_string_literal: true

module Maf
  module SetupAgent
    # Launcher replaces this process with the interactive session of a harness.
    # The harness file builds the command (Maf::Shared::Harnesses).
    module Launcher
      def self.launch(harness, role, model)
        ENV.update(harness.launch_env)
        exec_or_die(harness.launch(role, model))
      end

      def self.exec_or_die(cmd)
        Kernel.exec(*cmd)
      rescue Errno::ENOENT
        abort "setup_agent: '#{cmd.first}' not found on PATH."
      end
    end
  end
end
