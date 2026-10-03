# frozen_string_literal: true

require_relative "setup_agent"
require_relative "workers"
require_relative "worker_archive"

module Maf
  class Retire
    RUNTIME_PREFIXES = %w[.maf/ .claude/ .opencode/ .codex/].freeze

    def initialize(root, spec)
      @root = root
      @worker = Workers.id(spec)
      @dir = SetupAgent::Worktree.dir_for(root, @worker)
    end

    def check!
      abort "maf: no worker #{@worker}" unless Workers.at(@root).find(@worker) || Dir.exist?(@dir)
      stop_dispatcher
      pids = RunningProcesses.in(@dir)
      abort "maf: #{@worker} still runs (pid #{pids.join(", ")}). Stop its session, then run this again." if pids.any?
      abort "maf: #{@dir} has uncommitted work. Commit it on the task branch, then run this again." if dirty?
    end

    def run
      check!
      released = release_tasks
      remove_worker
      Team.notify(@root, "Team change: worker #{@worker} left. #{released} task(s) returned to the pool.")
      puts "Worker #{@worker} retired. #{released} task(s) returned to the pool."
    end

    private

    def role = Workers.at(@root).find(@worker)&.fetch("role") || @worker.sub(/-[^-]+\z/, "")

    def stop_dispatcher
      pid = Workers.at(@root).find(@worker)&.fetch("pid", nil)
      return unless pid && RunningProcesses.alive?(pid)

      puts "Stopping the dispatcher of #{@worker} (pid #{pid}). A running agent finishes first."
      Process.kill("TERM", pid)
      abort "maf: pid #{pid} did not stop. Stop it with: kill #{pid}" unless RunningProcesses.wait_for_exit(pid)
    end

    def release_tasks
      env = { "COORD_ROLE" => role, "COORD_WORKER" => @worker }
      ids = Team.coord(@root, "next", "--mine", env: env).scan(/^[0-9a-f-]{36}/)
      ids.each { |id| release(id) }
      ids.size
    end

    def release(id)
      Team.coord(@root, "unclaim", id)
      Team.coord(@root, "annotate", id, "Worker #{@worker} was retired. Continue on the existing task branch.")
    end

    def remove_presence
      coord_dir = File.join(@root, ".maf", "coordination")
      FileUtils.rm_f(File.join(coord_dir, "presence", "#{@worker}.json"))
    end

    def remove_worker
      remove_worktree
      WorkerArchive.new(@root, @worker).run
      remove_presence
      Workers.at(@root).remove(@worker)
    end

    def dirty?
      return false unless Dir.exist?(@dir)

      lines = IO.popen(["git", "-C", @dir, "status", "--porcelain"], err: File::NULL, &:readlines)
      lines.map { |line| line[3..].strip }.any? { |path| RUNTIME_PREFIXES.none? { |prefix| path.start_with?(prefix) } }
    end

    def remove_worktree
      return unless Dir.exist?(@dir)

      system("git", "-C", @root, "worktree", "remove", "--force", @dir, out: File::NULL) ||
        warn("maf: could not remove #{@dir}. Remove it with: git worktree remove #{@dir}")
    end
  end

  # RunningProcesses finds processes whose working directory is inside DIR.
  # A harness session or a dispatcher runs in its worktree.
  module RunningProcesses
    def self.in(dir)
      out = IO.popen(%w[lsof -a -d cwd -Fpn], err: File::NULL, &:read)
      pairs(out).select { |_pid, path| path == dir || path.start_with?("#{dir}/") }.map(&:first) - [Process.pid]
    rescue Errno::ENOENT
      warn "maf: lsof not found. Cannot check if the worker still runs."
      []
    end

    def self.alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # A dispatcher run can take up to its --timeout (default 1500 seconds).
    def self.wait_for_exit(pid, timeout: Integer(ENV.fetch("MAF_STOP_TIMEOUT", "1800")))
      deadline = Time.now + timeout
      sleep 0.5 while alive?(pid) && Time.now < deadline
      !alive?(pid)
    end

    def self.pairs(out)
      out.lines(chomp: true).slice_before { |line| line.start_with?("p") }
         .map { |group| [group.first[1..].to_i, group.find { |line| line.start_with?("n") }.to_s[1..].to_s] }
    end
  end
end
