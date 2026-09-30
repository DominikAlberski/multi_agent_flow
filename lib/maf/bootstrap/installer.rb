# frozen_string_literal: true

module Bootstrap
  # Installer runs the install: check dependencies, plan the actions, apply
  # them, start the vault, and print the next steps.
  class Installer
    # Each step is [planner, method]. The order is the order of the output.
    PLAN_STEPS = [
      %i[layout dirs], %i[layout gitkeeps], %i[scripts coord], %i[scripts dispatcher], %i[scripts vault],
      %i[scripts dashboard], %i[text taskrc], %i[text claude_md], %i[text contracts], %i[text gitignore],
      %i[scripts hooks], %i[scripts opencode_plugin], %i[claude plan], %i[scripts commit_guard]
    ].freeze

    def initialize(argv)
      @options = Options.new(argv)
    end

    def run
      validate_target
      @project = Project.new(@options.target, @options.force)
      Dependencies.new(@options).report
      GlobalTaskrcWarning.new(@project).run
      actions = plan
      return print_plan(actions) if @options.check

      Writer.new(@project).apply(actions)
      print_next_steps(VaultStarter.new(@project).start(actions))
    end

    private

    def validate_target
      target = @options.target
      abort "usage: bootstrap.rb /path/to/project [--roles a,b,c] [--check] [--force]" if target.nil?
      abort "target is not a directory: #{target}" unless Dir.exist?(target)
    end

    def plan
      planners = { layout: LayoutPlanner, scripts: ScriptPlanner, text: TextPlanner, claude: ClaudeSettings }
                 .transform_values { |klass| klass.new(@project) }
      PLAN_STEPS.flat_map { |planner, step| planners.fetch(planner).public_send(step) }
    end

    def print_plan(actions)
      actions.each { |act| Bootstrap.say(@project.format_action(act)) }
      puts "\n--check: no changes made."
    end

    def print_next_steps(vault_note)
      puts
      puts format(NEXT_STEPS, project: @project.target, roles: @options.roles, vault_note: vault_note)
    end
  end
end
