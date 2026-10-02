# frozen_string_literal: true

module Flow
  # Install hooks in the project. Preserve other hook definitions.
  class CodexHooks
    COMMAND = 'ruby "$(git rev-parse --show-toplevel)/.maf/coordination/harness-hooks/next-task.rb"'
    EVENTS = %w[SessionStart Stop].freeze

    def initialize(project)
      @path = File.join(project, ".codex", "hooks.json")
    end

    def install
      data = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
      EVENTS.each { |event| add(data, event) }
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(data))
    end

    private

    def add(data, event)
      entries = (data["hooks"] ||= {})[event] ||= []
      return if entries.any? { |entry| entry.fetch("hooks", []).any? { |hook| hook["command"] == COMMAND } }

      entries << { "hooks" => [{ "type" => "command", "command" => COMMAND }] }
    end
  end
end
