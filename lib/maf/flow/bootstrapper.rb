# frozen_string_literal: true

module Maf
  module Flow
    # Bootstrapper runs bootstrap.rb, which installs the board, the scripts,
    # and the hooks in the project.
    class Bootstrapper
      def initialize(options)
        @options = options
      end

      def run
        return if !@options.bootstrap? || @options.check?

        make_harness_dirs
        abort "flow: coordination bootstrap failed" unless system(*command)
      end

      private

      # Bootstrap adds the Claude Code hooks only if .claude/ exists, and the
      # opencode plugin only if .opencode/ exists. Flow writes the role files
      # after bootstrap, so create these dirs first.
      def make_harness_dirs
        used = %w[claude opencode] & @options.agents.map { |a| a[:harness] }
        used.each { |harness| FileUtils.mkdir_p(File.join(@options.project, ".#{harness}")) }
      end

      def command
        roles = @options.agents.map { |a| a[:role] }.uniq.join(",")
        args = [RbConfig.ruby, File.join(__dir__, "..", "bootstrap.rb"), @options.project, "--roles", roles]
        @options.force? ? args << "--force" : args
      end
    end
  end
end
