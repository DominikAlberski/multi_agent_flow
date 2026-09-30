# frozen_string_literal: true

module Bootstrap
  # ClaudeSettings plans and applies the Claude Code hooks in
  # .claude/settings.json. The hooks are installed only if .claude/ exists.
  class ClaudeSettings
    def initialize(project)
      @project = project
    end

    def plan
      return [] unless Dir.exist?(@project.path(".claude"))

      file = @project.path(".claude", "settings.json")
      [@project.action(status(file), file, "#{file} (next-task + board-watch hooks)", :claude_stop_hook)]
    end

    def configure(file)
      settings = read(file)
      missing = missing_hooks(settings)
      missing.each { |event, hook| add_hook(settings, event, hook) }
      write(file, settings) unless missing.empty?
      !missing.empty?
    end

    private

    def status(file)
      File.exist?(file) && missing_hooks(read(file)).empty? ? :skip : :configure_claude_hook
    end

    def read(file)
      File.exist?(file) ? (JSON.parse(File.read(file)) rescue {}) : {}
    end

    def missing_hooks(settings)
      CLAUDE_HOOKS.reject { |event, hook| hook_entry?(settings, event, hook["command"]) }
    end

    def hook_entry?(settings, event, command)
      (settings.dig("hooks", event) || []).any? { |entry| entry.dig("hooks", 0, "command") == command }
    end

    def add_hook(settings, event, hook)
      settings["hooks"] ||= {}
      (settings["hooks"][event] ||= []) << { "matcher" => "", "hooks" => [hook] }
    end

    def write(file, data)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, JSON.pretty_generate(data))
    end
  end
end
