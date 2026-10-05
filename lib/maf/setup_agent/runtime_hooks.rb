# frozen_string_literal: true

require_relative "../bootstrap"

module SetupAgent
  # Refresh owned hooks before the harness starts in an existing worktree.
  module RuntimeHooks
    def self.install(dir, harness)
      %w[next-task.rb board-watch.rb session-guard.rb context-watch.rb].each { |name| copy(dir, name) }
      configure(dir, harness)
      copy(dir, "board-watch-opencode.js", ".opencode/plugins/board-watch.js") if harness == "opencode"
    end

    # Claude Code reads the hooks from the settings file of the main project
    # (`maf start` passes it with --settings). The hook commands run in the
    # worktree, where the copies above live.
    def self.configure(dir, harness)
      root = Project.root
      settings = File.join(root, Bootstrap::CLAUDE_SETTINGS)
      Bootstrap::ClaudeSettings.new(Bootstrap::Project.new(root, false)).configure(settings) if harness == "claude"
      Flow::CodexHooks.new(dir).install if harness == "codex"
    end

    def self.copy(dir, name, relative = ".maf/coordination/harness-hooks/#{name}")
      path = File.join(dir, relative)
      abort "maf: #{path} is a foreign hook; the worker was not started" if foreign?(path, name)

      Flow::HookFiles.copy(File.join(Flow::ASSETS, "harness-hooks", name), path)
    end

    def self.foreign?(path, name)
      File.exist?(path) && !File.read(path).include?("#{name} -")
    end
  end
end
