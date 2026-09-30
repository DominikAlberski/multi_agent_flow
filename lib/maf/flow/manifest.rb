# frozen_string_literal: true

module Flow
  # Manifest writes .agent-flow.json, the record of the agents of a project.
  class Manifest
    def initialize(options, roles)
      @options = options
      @roles = roles
    end

    def write
      return if @options.check?

      File.write(path, JSON.pretty_generate(data))
    end

    private

    def path
      File.join(@options.project, ".agent-flow.json")
    end

    def data
      data = kept_keys.merge("generated_at" => Time.now.utc.iso8601, "agents" => @options.agents.map { |a| entry(a) })
      # Only record hermes_dir when it differs from the default: the default is
      # an absolute home path that would leak into a committed manifest.
      data["hermes_dir"] = @options.hermes_dir unless @options.hermes_dir == DEFAULT_HERMES_DIR
      data
    end

    # can_edit lets maf start, the dispatcher, and the git commit guard limit
    # a role without the role definitions.
    def entry(agent)
      { harness: agent[:harness], role: agent[:role], model: @options.model_for(agent),
        can_edit: @roles.fetch(agent[:role]).fetch("can_edit") }
    end

    # Other tools own other keys (maf team: "team"; users: "base_branch").
    # A re-run must keep them.
    def kept_keys
      return {} unless File.exist?(path)

      JSON.parse(File.read(path)).except("generated_at", "agents", "hermes_dir")
    rescue JSON::ParserError
      {}
    end
  end
end
