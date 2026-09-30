# frozen_string_literal: true

module Uninstall
  # Removes the flow hooks from .claude/settings.json. Other hooks and
  # settings stay. The file goes only if nothing else is left in it.
  class ClaudeSettings
    COMMANDS = Bootstrap::CLAUDE_HOOKS.map { |_, hook| hook["command"] }.uniq.freeze

    def initialize(project) = @path = File.join(project, ".claude", "settings.json")

    def steps
      return [] unless File.exist?(@path) && strip(settings) != settings

      [Step.new("remove flow hooks from #{@path}", -> { clean })]
    end

    private

    def settings = (JSON.parse(File.read(@path)) rescue {})

    def clean
      data = strip(settings)
      data.empty? ? FileUtils.rm(@path) : File.write(@path, JSON.pretty_generate(data))
    end

    def strip(data)
      hooks = data.fetch("hooks", {}).transform_values { |entries| strip_event(entries) }.reject { |_, v| v.empty? }
      hooks.empty? ? data.except("hooks") : data.merge("hooks" => hooks)
    end

    def strip_event(entries)
      entries.map { |entry| entry.merge("hooks" => entry.fetch("hooks", []).reject { |h| ours?(h) }) }
             .reject { |entry| entry["hooks"].empty? }
    end

    def ours?(hook) = COMMANDS.include?(hook["command"])
  end
end
