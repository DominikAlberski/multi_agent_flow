# frozen_string_literal: true

module Flow
  # McpConfig writes the graphify MCP server into the project config of a
  # harness. Claude Code reads .mcp.json. opencode reads opencode.json.
  # The server runs `vault mcp`. A foreign entry with the same name stays.
  # Codex and Hermes keep MCP servers in a global user file. maf does not
  # edit that file. It prints the command that adds the server instead.
  class McpConfig
    NAME = "graphify"
    ARGS = %w[ruby .maf/bin/vault mcp].freeze
    SCHEMA = "https://opencode.ai/config.json"
    TARGETS = {
      "claude" => { file: ".mcp.json", key: "mcpServers", entry: { "command" => ARGS.first, "args" => ARGS.drop(1) } },
      "opencode" => { file: "opencode.json", key: "mcp",
                      entry: { "type" => "local", "command" => ARGS, "enabled" => true } }
    }.freeze

    def self.targets = TARGETS

    # The shell command for a harness with a global MCP config, or nil.
    def self.global_command(harness, project)
      vault = File.join(project, ".maf", "bin", "vault")
      name = "#{NAME}-#{File.basename(project)}"
      case harness
      when "codex" then "codex mcp add #{name} -- ruby #{vault} mcp"
      when "hermes" then "hermes mcp add #{name} --command ruby --args #{vault} mcp"
      end
    end

    def initialize(project, harness)
      @target = TARGETS.fetch(harness)
      @path = File.join(project, @target[:file])
    end

    # Returns :create, :skip, or :refuse.
    def write
      data = load
      return :refuse unless data

      section = data.fetch(@target[:key], {})
      return (section[NAME] == @target[:entry] ? :skip : :refuse) if section.key?(NAME)

      save(data.merge(@target[:key] => section.merge(NAME => @target[:entry])))
      :create
    end

    private

    # An unreadable file gives nil. maf never overwrites a file it cannot read.
    def load
      data = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end

    def save(data)
      data = { "$schema" => SCHEMA }.merge(data) if @target[:key] == "mcp" && !data.key?("$schema")
      File.write(@path, "#{JSON.pretty_generate(data)}\n")
    end
  end
end
