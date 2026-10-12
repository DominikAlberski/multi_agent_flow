# frozen_string_literal: true

module Maf
  module Flow
    # RoleFiles renders and writes the role file of each agent.
    class RoleFiles
      MARKER = ">>> multi-agent-flow >>>"

      def initialize(options, roles)
        @options = options
        @roles = roles
        @prompts = PromptBuilder.new(roles, options.agents, Workflow.new(options.project).block)
      end

      def generate
        @options.agents.map { |agent| generate_agent(agent) }
      end

      private

      def generate_agent(agent)
        harness = Harness.fetch(agent[:harness])
        model = @options.model_for(agent)
        dest = harness.role_destination(@options.project, agent[:role], @options.settings)
        content = render(harness, agent[:role], @roles.fetch(agent[:role]), model)
        { agent: agent, dest: dest, status: write(dest, content), model: model }
      end

      def render(harness, role, data, model)
        harness.render_role(**template_values(role, data), prompt: @prompts.build(harness, role, data), model: model)
      end

      def template_values(role, data)
        { role: role, title: data.fetch("title"), description: data.fetch("description"),
          can_edit: data.fetch("can_edit"), project: File.expand_path(@options.project) }
      end

      def write(dest, content)
        existed = File.exist?(dest)
        return :skip if existed && File.read(dest) == content
        return :refuse if existed && refuse?(dest)

        @options.check? ? :check : save(dest, content, existed)
      end

      def save(dest, content, existed)
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, content)
        existed ? :update : :create
      end

      def refuse?(dest)
        !File.read(dest).include?(MARKER) && !@options.force?
      end
    end
  end
end
