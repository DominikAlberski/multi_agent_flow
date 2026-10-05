# frozen_string_literal: true

module Flow
  # Validator checks the project, the harnesses, and the roles of one run.
  class Validator
    def self.project!(options)
      project = options.project
      abort "flow: --project is required" if project.nil?
      abort "flow: project is not a directory: #{project}" unless Dir.exist?(project)

      options.project = File.realpath(project)
    end

    def initialize(options, roles)
      @options = options
      @roles = roles
    end

    # A removal may leave no agents. Only a run that removes nothing needs one.
    def run
      @options.agents = Roster.new(@options.project).merge(@options.agents, @options.removed)
      abort "flow: no agents. Add one with --agent HARNESS:ROLE" if @options.agents.empty? && @options.removed.empty?

      @options.agents.each { |agent| check(agent) }
    end

    private

    def check(agent)
      abort "flow: unknown harness '#{agent[:harness]}' (use #{HARNESSES.join(", ")})" unless known?(agent)
      abort "flow: unknown role '#{agent[:role]}'" unless @roles.key?(agent[:role])
    end

    def known?(agent) = HARNESSES.include?(agent[:harness])
  end
end
