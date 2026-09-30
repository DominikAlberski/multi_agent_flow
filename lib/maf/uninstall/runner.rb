# frozen_string_literal: true

module Uninstall
  class Runner
    USAGE = "Usage: maf uninstall [--check] [--yes] [--force]"

    def initialize(argv)
      @opts = {}
      OptionParser.new(USAGE) { |o| ["--project DIR", "--check", "--yes", "--force"].each { |f| o.on(f) } }
                  .parse!(argv, into: @opts)
    end

    def run
      steps = plan
      return finish("nothing to remove in #{project}") if steps.empty?

      steps.each { |step| say(step.label.gsub("#{project}/", "")) }
      @opts[:check] ? finish("check only; nothing removed") : apply(steps)
    end

    private

    def project
      abort USAGE unless @opts[:project] && Dir.exist?(@opts[:project])
      @project ||= File.realpath(@opts[:project])
    end

    def plan
      manifest = Manifest.new(project)
      [VaultWatcher.new(project), Worktrees.new(project, @opts[:force]), Scripts.new(project), CommitGuard.new(project),
       DocGraphHooks.new(project), RoleFiles.new(project, manifest), ClaudeSettings.new(project),
       MarkedFiles.new(project), Coordination.new(project), manifest].flat_map(&:steps)
    end

    def apply(steps)
      abort "uninstall: cancelled" unless @opts[:yes] || confirmed?
      steps.each(&:run)
      EMPTY_DIRS.each { |parts| Owned.prune(File.join(project, *parts)) }
      finish("removed the multi-agent flow from #{project}")
    end

    def confirmed?
      print "Remove the items above? [y/N] "
      $stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)
    end

    def finish(message)
      Notes.new(project).lines.each { |line| say(line) }
      say(message)
    end

    def say(message) = puts("[multi-agent-flow] #{message}")
  end
end
