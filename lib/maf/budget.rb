# frozen_string_literal: true

# budget.rb - team limits for maf prepare.
require "json"

module Maf
  # Budget reads the "team" key of .agent-flow.json:
  #   "team": { "max_workers": 6, "allow": ["claude", "opencode:deepseek/deepseek-v4-flash"] }
  # max_workers does not count the project manager. An "allow" entry without
  # a model allows every model of that harness. Without "team", maf sets no limits.
  class Budget
    LEAD = "project-manager"

    def self.at(root)
      path = File.join(root, ".agent-flow.json")
      new(File.exist?(path) ? JSON.parse(File.read(path)).fetch("team", {}) : {})
    end

    def initialize(team)
      @max = team["max_workers"]
      @allow = team.fetch("allow", [])
    end

    # With exactly one allowed model for the harness, maf uses that model.
    def default_model(harness)
      models = @allow.map { |spec| spec.split(":", 2) }.select { |name, _| name == harness }.map(&:last)
      models.size == 1 ? models.first : nil
    end

    def check!(harness, model, count)
      abort "maf: #{[harness, model].compact.join(":")} is not allowed. Allowed: #{@allow.join(", ")}" \
        unless allowed?(harness, model)
      abort "maf: the team would have #{count} workers. max_workers is #{@max}. Retire a worker first." \
        if @max && count > @max
    end

    def allowed?(harness, model)
      @allow.empty? || @allow.any? { |spec| [harness, "#{harness}:#{model}"].include?(spec) }
    end

    def count(workers) = workers.count { |_id, entry| entry["role"] != LEAD }

    def summary
      max = @max ? "max_workers #{@max}" : "no worker limit"
      allow = @allow.empty? ? "every harness" : @allow.join(", ")
      "Budget: #{max}. Allowed: #{allow}. The project manager does not count."
    end
  end
end
