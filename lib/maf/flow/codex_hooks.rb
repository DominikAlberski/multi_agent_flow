# frozen_string_literal: true

module Flow
  # Install hooks in the project. Preserve other hook definitions.
  class CodexHooks
    HOOKS_DIR = '"$(git rev-parse --show-toplevel)/.maf/coordination/harness-hooks'
    COMMANDS = %w[next-task.rb context-watch.rb].map { |name| %(ruby #{HOOKS_DIR}/#{name}") }.freeze
    EVENTS = %w[SessionStart Stop].freeze

    def initialize(project)
      @path = File.join(project, ".codex", "hooks.json")
    end

    def install
      data = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
      EVENTS.product(COMMANDS).each { |event, command| add(data, event, command) }
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(data))
    end

    private

    def add(data, event, command)
      entries = (data["hooks"] ||= {})[event] ||= []
      return if entries.any? { |entry| entry.fetch("hooks", []).any? { |hook| hook["command"] == command } }

      entries << { "hooks" => [{ "type" => "command", "command" => command }] }
    end
  end
end
