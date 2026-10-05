# frozen_string_literal: true

module Flow
  # McpConfig writes the graphify MCP server into a config file of the flow,
  # in .maf/mcp/. The project's .mcp.json and opencode.json stay as they are.
  # `maf start` and the dispatcher pass the file: Claude Code reads it with
  # --mcp-config, opencode with the OPENCODE_CONFIG variable.
  # The server runs `vault mcp`. A foreign entry with the same name stays.
  # Codex and Hermes keep MCP servers in a global user file. maf does not
  # edit that file. It prints the command that adds the server instead.
  class McpConfig
    NAME = "graphify"
    ARGS = %w[ruby .maf/bin/vault mcp].freeze
    SCHEMA = "https://opencode.ai/config.json"
    TARGETS = {
      "claude" => { file: ".maf/mcp/claude.json", key: "mcpServers",
                    entry: { "command" => ARGS.first, "args" => ARGS.drop(1) } },
      "opencode" => { file: ".maf/mcp/opencode.json", key: "mcp",
                      entry: { "type" => "local", "command" => ARGS, "enabled" => true } }
    }.freeze

    def self.targets = TARGETS

    GLOBAL_COMMANDS = { "codex" => "codex mcp add %<name>s -- ruby %<vault>s mcp",
                        "hermes" => "hermes mcp add %<name>s --command ruby --args %<vault>s mcp" }.freeze

    # The shell command for a harness with a global MCP config, or nil.
    def self.global_command(harness, project)
      vault = File.join(project, ".maf", "bin", "vault")
      GLOBAL_COMMANDS[harness]&.then { |text| format(text, name: "#{NAME}-#{File.basename(project)}", vault: vault) }
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
      section.key?(NAME) ? compare(section[NAME]) : add(data, section)
    end

    private

    def compare(entry) = entry == @target[:entry] ? :skip : :refuse

    def add(data, section)
      save(data.merge(@target[:key] => section.merge(NAME => @target[:entry])))
      :create
    end

    # An unreadable file gives nil. maf never overwrites a file it cannot read.
    def load
      data = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end

    def save(data)
      data = { "$schema" => SCHEMA }.merge(data) if @target[:key] == "mcp" && !data.key?("$schema")
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, "#{JSON.pretty_generate(data)}\n")
    end
  end
end
