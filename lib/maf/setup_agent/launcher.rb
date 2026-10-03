# frozen_string_literal: true

module SetupAgent
  module Launcher
    REGISTRY = {}

    def self.for(harness)
      register_defaults if REGISTRY.empty?
      REGISTRY.fetch(harness) { abort "setup_agent: no launcher for harness '#{harness}' yet." }
    end

    def self.register_defaults
      REGISTRY["claude"] = Claude
      REGISTRY["opencode"] = Opencode
      REGISTRY["codex"] = Codex
      REGISTRY["hermes"] = Hermes
    end

    def self.exec_or_die(cmd)
      Kernel.exec(*cmd)
    rescue Errno::ENOENT
      abort "setup_agent: '#{cmd.first}' not found on PATH."
    end

    module Claude
      def self.launch(role, _worker, model)
        prompt = "Read .maf/agents/claude/#{role}.md and follow it exactly. Start your work loop now."
        cmd = ["claude"]
        cmd += ["--model", model] if model
        Launcher.exec_or_die(cmd + [prompt])
      end
    end

    module Opencode
      def self.launch(role, _worker, model)
        cmd = ["opencode", ".", "--agent", role, "--prompt", "Start your work loop now."]
        cmd += ["--model", model] if model
        Launcher.exec_or_die(cmd)
      end
    end

    module Codex
      def self.launch(role, _worker, model)
        prompt_file = ".codex/prompts/#{role}.md"
        abort "setup_agent: #{prompt_file} missing." unless File.exist?(prompt_file)

        cmd = ["codex"]
        cmd += ["--model", model] if model
        Launcher.exec_or_die(cmd + [File.read(prompt_file)])
      end
    end
  end
end
