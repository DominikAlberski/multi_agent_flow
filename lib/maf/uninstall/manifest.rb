# frozen_string_literal: true

module Maf
  module Uninstall
    # .maf/config.json lists the generated agents. Hermes skills live outside
    # the project, so only the manifest tells which ones belong to it.
    class Manifest
      def initialize(project)
        @project = project
        @path = File.join(project, ".maf/config.json")
      end

      def steps = File.exist?(@path) ? [Owned.remove(@path)] : []

      def hermes_skills
        roles = data.fetch("agents", []).select { |a| a["harness"] == "hermes" }.map { |a| a["role"] }
        roles.map { |role| File.join(hermes_dir, "#{File.basename(@project)}-#{role}", "SKILL.md") }
      end

      private

      def hermes_dir = data.fetch("hermes_dir", Flow::DEFAULT_HERMES_DIR)

      def data
        @data ||= File.exist?(@path) ? (JSON.parse(File.read(@path)) rescue {}) : {}
      end
    end
  end
end
