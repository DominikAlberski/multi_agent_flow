# frozen_string_literal: true

require "shellwords"

module Flow
  # Remove only the global hook that MAF installed.
  class LegacyCodexHook
    DISABLED = <<~RUBY
      #!/usr/bin/env ruby
      # next-task.rb - Stop hook for Claude Code and Codex.
      # The legacy global MAF hook is disabled. Use project hooks with maf start.
      exit 0
    RUBY

    def initialize(home = Dir.home)
      @script = File.join(home, ".codex", "hooks", "next-task.rb")
      @path = File.join(home, ".codex", "hooks.json")
    end

    def remove
      return unless owned?

      disable
      clean_config if File.exist?(@path)
    end

    def clean_config
      clean(JSON.parse(File.read(@path)))
    rescue JSON::ParserError
      warn "flow: invalid JSON in #{@path}; the legacy hook is disabled but its registration remains"
    end

    private

    def disable
      File.write(@script, DISABLED) unless File.read(@script) == DISABLED
    end

    def owned?
      File.file?(@script) && File.read(@script).include?("next-task.rb - Stop hook for Claude Code and Codex.")
    end

    def clean(data)
      updated = stripped(data)
      return if updated == data

      File.write(@path, JSON.pretty_generate(updated))
      puts "  hook remove:  #{@path} (legacy global MAF hook)"
    end

    def stripped(data)
      hooks = data.fetch("hooks", {}).transform_values { |entries| strip_entries(entries) }.reject { |_, v| v.empty? }
      hooks.empty? ? data.except("hooks") : data.merge("hooks" => hooks)
    end

    def strip_entries(entries)
      entries.map { |entry| entry.merge("hooks" => entry.fetch("hooks", []).reject { |hook| ours?(hook) }) }
        .reject { |entry| entry["hooks"].empty? }
    end

    def ours?(hook)
      command = Shellwords.split(hook["command"].to_s)
      command.size == 2 && File.basename(command.first) == "ruby" &&
        [@script, "~/.codex/hooks/next-task.rb"].include?(command.last)
    rescue ArgumentError
      false
    end
  end
end
