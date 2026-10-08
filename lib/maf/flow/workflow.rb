# frozen_string_literal: true

module Maf
  module Flow
    # Workflow reads the stage instructions of a project from .maf/workflow.md.
    # Only the orchestrator prompt receives the text.
    class Workflow
      FILE = ".maf/workflow.md"
      HEADING = "Workflow:"

      def initialize(project)
        @path = File.join(project, FILE)
      end

      # The prompt block, or nil if the project has no workflow.
      def block
        return nil unless File.exist?(@path)

        text = File.read(@path).strip
        text.empty? ? nil : "#{HEADING}\n#{indent(text)}"
      end

      private

      def indent(text) = text.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
    end
  end
end
