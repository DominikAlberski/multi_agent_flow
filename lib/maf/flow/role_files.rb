# frozen_string_literal: true

module Flow
  # RoleFiles renders and writes the role file of each agent.
  class RoleFiles
    MARKER = ">>> multi-agent-flow >>>"

    def initialize(options, roles)
      @options = options
      @roles = roles
      @prompts = PromptBuilder.new(roles, options.agents)
    end

    def generate
      @options.agents.map { |agent| generate_agent(agent) }
    end

    private

    def generate_agent(agent)
      role = agent[:role]
      model = @options.model_for(agent)
      dest = destination(agent[:harness], role)
      content = render(agent[:harness], role, @roles.fetch(role), model)
      { agent: agent, dest: dest, status: write(dest, content), model: model }
    end

    def destination(harness, role)
      case harness
      when "opencode", "claude", "codex" then File.join(@options.project, Flow.role_path(harness, role))
      # Hermes skills live in a global ~/.hermes/skills/ directory, not the
      # project. Namespace by project so two projects using the same role
      # don't overwrite each other's skill.
      when "hermes" then hermes_path(role)
      end
    end

    def hermes_path(role)
      File.join(@options.hermes_dir, "#{File.basename(@options.project)}-#{role}", "SKILL.md")
    end

    def render(harness, role, data, model)
      template = File.read(File.join(TEMPLATES, "#{harness}.md.erb"))
      ERB.new(template, trim_mode: "-").result_with_hash(
        role: role, title: data.fetch("title"), description: data.fetch("description"),
        prompt: @prompts.build(harness, role, data), model: model, can_edit: data.fetch("can_edit")
      )
    end

    def write(dest, content)
      existed = File.exist?(dest)
      return :skip if existed && File.read(dest) == content
      return :refuse if existed && refuse?(dest)
      return :check if @options.check?

      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, content)
      existed ? :update : :create
    end

    def refuse?(dest)
      !File.read(dest).include?(MARKER) && !@options.force?
    end
  end
end
