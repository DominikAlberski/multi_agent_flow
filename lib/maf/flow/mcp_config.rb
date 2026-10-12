# frozen_string_literal: true

module Maf
  module Flow
    # McpConfig writes the graphify MCP server into a config file of the flow,
    # in .maf/mcp/. The project's own config files stay as they are. maf start
    # and the dispatcher pass the file to the harness (Harness#launch and
    # Harness#build_command). Harness#mcp names the file and the entry.
    # The server runs `vault mcp`. A foreign entry with the same name stays.
    # A harness with a global MCP config gives a command instead
    # (Harness#mcp_command). maf does not edit that file. It prints the command.
    class McpConfig
      NAME = "graphify"

      # The shell command for a harness with a global MCP config, or nil.
      def self.global_command(harness, project)
        harness.mcp_command("#{NAME}-#{File.basename(project)}", File.join(project, ".maf", "bin", "vault"))
      end

      def initialize(project, harness)
        @target = harness.mcp
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
        data = { "$schema" => @target[:schema] }.merge(data) if @target[:schema] && !data.key?("$schema")
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, "#{JSON.pretty_generate(data)}\n")
      end
    end
  end
end
