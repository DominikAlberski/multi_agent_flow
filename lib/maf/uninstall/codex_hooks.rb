# frozen_string_literal: true

module Uninstall
  # Remove project MAF hooks. Preserve other project hooks.
  class CodexHooks < ClaudeSettings
    def initialize(project)
      @path = File.join(project, ".codex", "hooks.json")
    end

    private

    def ours?(hook)
      Flow::CodexHooks::COMMANDS.include?(hook["command"])
    end
  end
end
