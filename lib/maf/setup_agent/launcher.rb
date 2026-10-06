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

    # FlowFiles finds the files of the flow in .maf/ of the main project. The
    # project's own harness config stays as it is: each file of the flow is
    # passed to the harness at the start.
    module FlowFiles
      def self.path(*parts) = File.join(Project.root, ".maf", *parts)
      def self.flag(name, *parts) = File.exist?(path(*parts)) ? [name, path(*parts)] : []
    end

    # --settings adds the hooks of the flow, --mcp-config adds the graph server.
    # --mcp-config takes many values, so `--` ends the options before the prompt.
    module Claude
      def self.launch(role, _worker, model)
        prompt = "Read .maf/agents/claude/#{role}.md and follow it exactly. Start your work loop now."
        cmd = ["claude", *FlowFiles.flag("--settings", "claude", "settings.json"),
               *FlowFiles.flag("--mcp-config", "mcp", "claude.json")]
        Launcher.exec_or_die(cmd + (model ? ["--model", model] : []) + ["--", prompt])
      end
    end

    # opencode merges the file in OPENCODE_CONFIG with the project's opencode.json.
    module Opencode
      def self.launch(role, _worker, model)
        config = FlowFiles.path("mcp", "opencode.json")
        ENV["OPENCODE_CONFIG"] = config if File.exist?(config)
        cmd = ["opencode", ".", "--agent", role, "--prompt", "Start your work loop now."]
        Launcher.exec_or_die(cmd + (model ? ["--model", model] : []))
      end
    end

    module Codex
      def self.launch(role, _worker, model)
        prompt_file = ".codex/prompts/#{role}.md"
        abort "setup_agent: #{prompt_file} missing." unless File.exist?(prompt_file)

        cmd = ["codex", *writable_dirs]
        cmd += ["--model", model] if model
        warn_untrusted
        Launcher.exec_or_die(cmd + [File.read(prompt_file)])
      end

      UNTRUSTED = "maf: Codex does not trust the hooks in %<file>s yet. Trust them when Codex asks. " \
                  "Without the hooks, the session records no token usage, and coord await cannot wake it."

      # Codex runs the hooks of a project only after the user trusts them, and
      # a worktree is a new project for Codex. Codex records the trust in its config.toml.
      def self.warn_untrusted
        hooks = File.join(File.realpath(Dir.pwd), ".codex", "hooks.json")
        config = File.join(ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex")), "config.toml")
        trusted = File.exist?(config) && File.read(config).include?("#{hooks}:stop:")
        warn format(UNTRUSTED, file: hooks) if File.exist?(hooks) && !trusted
      end

      # The worktree is the only writable root of the Codex sandbox. coord
      # writes the board and the artifacts in .maf/coordination of the main
      # project, so Codex would ask for approval at each coord command.
      def self.writable_dirs = ["--add-dir", File.join(SetupAgent::Project.root, ".maf", "coordination")]
    end
  end
end
