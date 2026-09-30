# frozen_string_literal: true

module Flow
  # HookInstaller installs the harness hooks that pick up tasks when a
  # session ends. Claude Code and opencode get theirs from bootstrap.
  class HookInstaller
    def initialize(agents)
      @harnesses = agents.map { |a| a[:harness] }.uniq
    end

    # Returns true when the Hermes hook needs steps from the user.
    def install
      install_codex if @harnesses.include?("codex")
      @harnesses.include?("hermes") && HermesHookSetup.new.install
    end

    private

    def install_codex
      dest = File.join(Dir.home, ".codex", "hooks", "next-task.rb")
      HookFiles.copy(File.join(ASSETS, "harness-hooks", "next-task.rb"), dest)
      merge_stop_hook(File.join(Dir.home, ".codex", "hooks.json"), dest)
    end

    def merge_stop_hook(hooks_json, script_path)
      data = File.exist?(hooks_json) ? (JSON.parse(File.read(hooks_json)) rescue {}) : {}
      stop = (data["hooks"] ||= {})["Stop"] ||= []
      return if stop.any? { |e| e.dig("hooks", 0, "command").to_s.include?("next-task.rb") }

      stop << { "matcher" => "", "hooks" => [{ "type" => "command", "command" => "ruby #{script_path}" }] }
      File.write(hooks_json, JSON.pretty_generate(data))
      puts "  hook merge:   #{hooks_json} (Stop hook added)"
    end
  end
end
