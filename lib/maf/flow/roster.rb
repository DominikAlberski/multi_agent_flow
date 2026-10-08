# frozen_string_literal: true

module Maf
  module Flow
    # Roster merges the agents saved in .maf/config.json with the --agent and
    # --remove specs of this run. A saved model ranks below --model.
    class Roster
      def initialize(project)
        path = File.join(project, ".maf/config.json")
        @saved = File.exist?(path) ? JSON.parse(File.read(path)).fetch("agents", []) : []
      end

      def merge(added, removed)
        kept = saved.map { |a| added.find { |b| same?(a, b) }&.merge(saved_model: a[:saved_model]) || a }
        agents = kept + added.reject { |b| kept.any? { |a| same?(a, b) } }
        agents.reject { |a| removed.any? { |b| same?(a, b) } }
      end

      private

      def saved
        @saved.map { |a| { harness: a["harness"], role: a["role"], saved_model: a["model"] } }
      end

      def same?(one, other) = one[:harness] == other[:harness] && one[:role] == other[:role]
    end
  end
end
