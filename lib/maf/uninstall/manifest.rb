# frozen_string_literal: true

module Maf
  module Uninstall
    # .maf/config.json lists the generated agents. Some harnesses keep role
    # files outside the project, so only the manifest tells which ones belong to it.
    class Manifest
      def initialize(project)
        @project = project
        @path = File.join(project, ".maf/config.json")
      end

      def steps = File.exist?(@path) ? [Owned.remove(@path)] : []

      # The role files of the harnesses that keep them outside .maf/agents/.
      def outside_role_files
        data.fetch("agents", []).filter_map do |agent|
          harness = Maf::Shared::Harness[agent["harness"]]
          harness.role_destination(@project, agent["role"], data) if harness && !harness.role_path(agent["role"])
        end
      end

      private

      def data
        @data ||= File.exist?(@path) ? (JSON.parse(File.read(@path)) rescue {}) : {}
      end
    end
  end
end
