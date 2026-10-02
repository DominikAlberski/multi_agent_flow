# frozen_string_literal: true

require_relative "../bootstrap"

module SetupAgent
  # Refresh owned hooks before the harness starts in an existing worktree.
  module RuntimeHooks
    def self.install(dir, harness)
      %w[next-task.rb board-watch.rb session-guard.rb].each { |name| copy(dir, name) }
      configure(dir, harness)
      copy(dir, "board-watch-opencode.js", ".opencode/plugins/board-watch.js") if harness == "opencode"
    end

    def self.configure(dir, harness)
      project = Bootstrap::Project.new(dir, false)
      settings = File.join(dir, ".claude/settings.json")
      Bootstrap::ClaudeSettings.new(project).configure(settings) if harness == "claude"
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
