# frozen_string_literal: true

module SetupAgent
  class Manifest
    def self.load(path)
      abort_missing(path) unless File.exist?(path)

      new(JSON.parse(File.read(path))["agents"])
    end

    def self.abort_missing(path)
      abort "setup_agent: #{path} missing. Fix: maf add HARNESS:ROLE"
    end

    def initialize(agents)
      @agents = agents
    end

    def verify!(harness, role)
      return if @agents.any? { |a| a["harness"] == harness && a["role"] == role }

      abort "setup_agent: no #{harness}:#{role} in .maf/config.json.\n#{add_hint("#{harness}:#{role}")}"
    end

    # maf add keeps the current agents, so the hint names only the missing agent.
    def add_hint(missing) = "  Fix: maf add #{missing}"

    def model_for(harness, role)
      entry = @agents.find { |a| a["harness"] == harness && a["role"] == role }
      entry && entry["model"]
    end
  end
end
