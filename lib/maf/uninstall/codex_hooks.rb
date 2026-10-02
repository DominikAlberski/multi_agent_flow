# frozen_string_literal: true

module Uninstall
  # Remove project MAF hooks. Preserve other project hooks.
  class CodexHooks < ClaudeSettings
    def initialize(project)
      @path = File.join(project, ".codex", "hooks.json")
    end

    private

    def ours?(hook)
      hook["command"] == Flow::CodexHooks::COMMAND
    end
  end
end
