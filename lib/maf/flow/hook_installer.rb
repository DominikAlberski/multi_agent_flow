# frozen_string_literal: true

module Flow
  # HookInstaller installs the harness hooks that pick up tasks when a
  # session ends. Claude Code and opencode get theirs from bootstrap.
  class HookInstaller
    def initialize(agents, project)
      @harnesses = agents.map { |a| a[:harness] }.uniq
      @project = project
    end

    # Returns true when the Hermes hook needs steps from the user.
    def install
      install_codex if @harnesses.include?("codex")
      @harnesses.include?("hermes") && HermesHookSetup.new.install
    end

    private

    def install_codex
      %w[next-task.rb session-guard.rb].each { |name| copy_hook(name) }
      CodexHooks.new(@project).install
      LegacyCodexHook.new.remove
    end

    def copy_hook(name)
      HookFiles.copy(File.join(ASSETS, "harness-hooks", name),
                     File.join(@project, ".maf", "coordination", "harness-hooks", name))
    end
  end
end
