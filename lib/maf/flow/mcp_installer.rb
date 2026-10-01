# frozen_string_literal: true

module Flow
  # McpInstaller adds the graphify MCP server for each harness of the run.
  # The key "mcp": false in .maf/config.json turns it off.
  class McpInstaller
    def initialize(options)
      @options = options
      @project = options.project
    end

    def install
      return if @options.check? || disabled?

      @options.agents.map { |a| a[:harness] }.uniq.each { |harness| install_for(harness) }
    end

    private

    def install_for(harness)
      if McpConfig.targets.key?(harness)
        report(harness, McpConfig.new(@project, harness).write)
      elsif (command = McpConfig.global_command(harness, @project))
        puts "mcp: the #{harness} harness keeps MCP servers in a global file. Add the server yourself:\n  #{command}"
      end
    end

    def report(harness, status)
      file = McpConfig.targets.fetch(harness).fetch(:file)
      return puts("mcp: wrote the graphify server to #{file}") if status == :create
      return unless status == :refuse

      warn "mcp: #{file} has another graphify entry, or it is not valid JSON. maf left the file as it is."
    end

    def disabled?
      path = File.join(@project, ".maf", "config.json")
      File.exist?(path) && JSON.parse(File.read(path))["mcp"] == false
    rescue JSON::ParserError
      false
    end
  end
end
