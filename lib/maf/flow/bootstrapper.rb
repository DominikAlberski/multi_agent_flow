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

      # Bootstrap installs the hooks of a harness only if its folder exists
      # (Harness#bootstrap_dir). Flow writes the role files after bootstrap,
      # so create these dirs first.
      def make_harness_dirs
        dirs = @options.agents.map { |a| Harness.fetch(a[:harness]).bootstrap_dir }.compact.uniq
        dirs.each { |dir| FileUtils.mkdir_p(File.join(@options.project, dir)) }
      end

      def command
        roles = @options.agents.map { |a| a[:role] }.uniq.join(",")
        args = [RbConfig.ruby, File.join(__dir__, "..", "bootstrap.rb"), @options.project, "--roles", roles]
        @options.force? ? args << "--force" : args
      end
    end
  end
end
