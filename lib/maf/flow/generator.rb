# frozen_string_literal: true

module Flow
  # Generator runs one maf add, remove, update, or roles command.
  class Generator
    # Flags that take a value. maf uses them to tell flag values from agent specs.
    def self.value_flags = Options.new([]).value_flags

    def initialize(argv)
      @options = Options.new(argv)
    end

    def run
      @options.parse
      validate_project
      @catalog = RoleCatalog.new(@options.project)
      @roles = @catalog.roles
      return print_roles if @options.list_roles

      validate
      return finish_without_agents if @options.agents.empty?

      generate_all
    end

    private

    def generate_all
      run_bootstrap
      results = RoleFiles.new(@options, @roles).generate
      link_agents
      pending = @options.check? ? false : HookInstaller.new(@options.agents).install
      manifest.write
      Report.new(@options.project, @roles, pending).print(results)
    end

    def manifest = Manifest.new(@options, @roles)

    # Point the folder of each harness at the role files in .maf/agents/.
    def link_agents
      return if @options.check?

      links = AgentLinks.new(@options.project)
      @options.agents.map { |a| a[:harness] }.uniq.select { |h| HARNESS_DIRS.key?(h) }.each do |harness|
        warn_not_linked(harness) if links.link(harness) == :refuse
      end
    end

    def warn_not_linked(harness)
      warn "flow: #{HARNESS_DIRS.fetch(harness)} holds files that the flow does not own. " \
           "The #{harness} harness cannot read the role files. Run: maf migrate"
    end

    def print_roles
      puts "Available roles (model_hint is a recommendation only):"
      @roles.each do |key, data|
        puts
        puts "  #{key} (#{@catalog.source(key)})"
        puts "    #{data.fetch("description")}"
        puts "    model hint: #{data.fetch("model_hint")}"
      end
    end

    def validate
      @options.agents = Roster.new(@options.project).merge(@options.agents, @options.removed)
      validate_agents
    end

    def validate_project
      project = @options.project
      abort "flow: --project is required" if project.nil?
      abort "flow: project is not a directory: #{project}" unless Dir.exist?(project)

      @options.project = File.realpath(project)
    end

    # A removal may leave no agents. Only a run that removes nothing needs one.
    def validate_agents
      abort "flow: no agents. Add one with --agent HARNESS:ROLE" if @options.agents.empty? && @options.removed.empty?

      @options.agents.each { |agent| validate_agent(agent) }
    end

    def validate_agent(agent)
      unless HARNESSES.include?(agent[:harness])
        abort "flow: unknown harness '#{agent[:harness]}' (use #{HARNESSES.join(", ")})"
      end
      abort "flow: unknown role '#{agent[:role]}'" unless @roles.key?(agent[:role])
    end

    def finish_without_agents
      manifest.write
      puts "No agents left. Add one: maf add HARNESS:ROLE. Remove the flow: maf uninstall."
    end

    def run_bootstrap
      return if !@options.bootstrap? || @options.check?

      # Bootstrap adds the Claude Code hooks only if .claude/ exists, and the
      # opencode plugin only if .opencode/ exists. Flow writes the role files
      # after bootstrap, so create these dirs first.
      make_harness_dirs
      abort "flow: coordination bootstrap failed" unless system(*bootstrap_command)
    end

    def make_harness_dirs
      %w[claude opencode].each do |harness|
        next unless @options.agents.any? { |a| a[:harness] == harness }

        FileUtils.mkdir_p(File.join(@options.project, ".#{harness}"))
      end
    end

    def bootstrap_command
      roles = @options.agents.map { |a| a[:role] }.uniq.join(",")
      args = [RbConfig.ruby, File.join(__dir__, "..", "bootstrap.rb"), @options.project, "--roles", roles]
      @options.force? ? args << "--force" : args
    end
  end
end
