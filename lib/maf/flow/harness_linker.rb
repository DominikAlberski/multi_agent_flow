# frozen_string_literal: true

module Maf
  module Flow
    # HarnessLinker points the folder of each harness at the role files in
    # .maf/agents/. A folder with the user's own files gets one link per role.
    class HarnessLinker
      def initialize(options)
        @options = options
        @links = AgentLinks.new(options.project)
      end

      def run
        return if @options.check?

        harnesses.each { |harness| link_role_files(harness) if @links.link(harness) == :refuse }
      end

      private

      def harnesses = @options.agents.map { |a| a[:harness] }.uniq.select { |h| HARNESS_DIRS.key?(h) }
      def dir(harness) = HARNESS_DIRS.fetch(harness)

      def link_role_files(harness)
        return warn_not_linked(harness) if File.symlink?(File.join(@options.project, dir(harness)))

        kept = @links.link_files(harness)
        warn "flow: #{dir(harness)} has own files named #{kept.join(", ")}. Those roles are not linked." if kept.any?
      end

      def warn_not_linked(harness)
        warn "flow: #{dir(harness)} points to another folder. " \
             "The #{harness} harness cannot read the role files. Run: maf migrate"
      end
    end
  end
end
