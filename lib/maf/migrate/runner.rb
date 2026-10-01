# frozen_string_literal: true

module Migrate
  # Runner plans the migration, prints the plan, asks, and applies it.
  class Runner
    USAGE = "Usage: maf migrate [--check] [--yes]"

    def initialize(argv)
      @opts = {}
      OptionParser.new(USAGE) { |o| ["--project DIR", "--check", "--yes"].each { |f| o.on(f) } }.parse!(argv, into: @opts)
    end

    def run
      steps = plan
      return say("nothing to migrate in #{project}") if steps.empty?

      steps.each { |step| say(step.label) }
      @opts[:check] ? say("check only; nothing moved") : apply(steps)
    end

    private

    def project
      abort USAGE unless @opts[:project] && Dir.exist?(@opts[:project])
      @project ||= File.realpath(@opts[:project])
    end

    def plan
      return [] unless Migrate.old_layout?(project)

      [Moves, Worktrees, Rewrites, RoleFiles].flat_map { |planner| planner.new(project).steps }
    end

    def apply(steps)
      abort "migrate: cancelled" unless @opts[:yes] || confirmed?
      abort "migrate: a worker still runs. Stop it, then run this again." if running_workers.any?
      steps.each(&:run)
      regenerate
      say("moved the flow into #{project}/.maf. Review with git status. Then commit the move.")
    end

    def confirmed?
      print "Move the files above? [y/N] "
      $stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)
    end

    # A dispatcher in the background keeps the old paths. The registry lists its pid.
    def running_workers
      path = [".maf/coordination", "coordination"].map { |dir| File.join(project, dir, "workers.json") }.find { |f| File.exist?(f) }
      pids = path ? JSON.parse(File.read(path)).values.filter_map { |entry| entry["pid"] } : []
      pids.select { |pid| alive?(pid) }
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Regenerate the files of the current agents: scripts, role files, symlinks,
    # hooks, and the marked blocks. This is the same step as maf update.
    def regenerate
      Flow::Generator.new(["--project", project]).run if File.exist?(File.join(project, ".maf", "config.json"))
    end

    def say(message) = puts("[multi-agent-flow] #{message}")
  end
end
