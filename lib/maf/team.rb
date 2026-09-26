# frozen_string_literal: true

# team.rb - add, replace, and retire workers in one command.
#
#   maf prepare HARNESS ROLE[_WORKER] [--model M] [--dispatch] [--replace WORKER]
#   maf retire WORKER
#
# The project manager runs these commands for the user. `maf prepare` adds
# the role file, creates the worktree, and registers the worker. The user
# then runs two commands: `cd <worktree>` and `maf start`.
require "rbconfig"
require_relative "setup_agent"
require_relative "workers"

module Maf
  module Team
    def self.coord(root, *args, env: {})
      IO.popen(env, [RbConfig.ruby, File.join(root, "coord"), *args], chdir: root, err: File::NULL, &:read).to_s
    end

    def self.notify(root, text) = coord(root, "msg", "--from", "maf", "architect", text)
  end

  # Prepare makes a worker ready to start. With --replace, it retires the
  # old worker, so the old worker's tasks return to the pool. If the old and
  # the new worker have the same id (only the harness or the model changes),
  # the worker keeps its worktree and its claims.
  class Prepare
    def initialize(argv)
      @replace = take_replace(argv)
      @args = SetupAgent::Args.parse(argv)
      @root = SetupAgent::Project.root
    end

    def run
      retire = @replace && Retire.new(@root, @replace)
      retire&.check!
      Dir.chdir(@root) { prepare }
      retire.run if retire && Workers.id(@replace) != @args.worker
      Team.notify(@root, "Team change: worker #{@args.worker} (#{@args.harness}) joined as #{@args.role}.")
      print_next_steps
    end

    private

    def take_replace(argv)
      index = argv.index("--replace") or return nil
      argv.slice!(index, 2)[1] || abort("maf: --replace needs a worker, for example backend-developer_2")
    end

    def prepare
      Maf.flow("--agent", spec) unless Maf.agent_specs.include?("#{@args.harness}:#{@args.role}")
      worktree = SetupAgent::Worktree.ensure(@args.role, @args.worker_id, @args.harness)
      SetupAgent::RoleFile.copy(@root, worktree.dir, @args.harness, @args.role)
      Workers.at(@root).add(@args.worker, entry(worktree.dir))
    end

    def spec = [@args.harness, @args.role, @args.model].compact.join(":")

    def entry(dir)
      { "role" => @args.role, "worker_id" => @args.worker_id, "harness" => @args.harness,
        "model" => @args.model, "dispatch" => @args.dispatch, "dir" => dir }.compact
    end

    def print_next_steps
      dir = SetupAgent::Worktree.dir_for(@root, @args.worker)
      puts "", "Worker #{@args.worker} is ready. Run in a new terminal:", "  cd #{dir}", "  maf start"
    end
  end

  # Retire removes a worker: it returns the worker's claimed tasks to the
  # pool, removes the worktree, and deletes the registry entry. The task
  # branches stay, so the next worker continues from the committed work.
  class Retire
    RUNTIME_PREFIXES = %w[coord coordination/ .claude/ .opencode/ .codex/ dispatcher dashboard vault].freeze

    def initialize(root, spec)
      @root = root
      @worker = Workers.id(spec)
      @dir = SetupAgent::Worktree.dir_for(root, @worker)
    end

    def check!
      abort "maf: no worker #{@worker}" unless Workers.at(@root).find(@worker) || Dir.exist?(@dir)
      pids = RunningProcesses.in(@dir)
      abort "maf: #{@worker} still runs (pid #{pids.join(", ")}). Stop its session, then run this again." if pids.any?
      abort "maf: #{@dir} has uncommitted work. Commit it on the task branch, then run this again." if dirty?
    end

    def run
      check!
      released = release_tasks
      remove_worktree
      Workers.at(@root).remove(@worker)
      Team.notify(@root, "Team change: worker #{@worker} left. #{released} task(s) returned to the pool.")
      puts "Worker #{@worker} retired. #{released} task(s) returned to the pool."
    end

    private

    def role = Workers.at(@root).find(@worker)&.fetch("role") || @worker.sub(/-[^-]+\z/, "")

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

    def dirty?
      return false unless Dir.exist?(@dir)

      lines = IO.popen(["git", "-C", @dir, "status", "--porcelain"], err: File::NULL, &:readlines)
      lines.map { |line| line[3..].strip }.any? { |path| RUNTIME_PREFIXES.none? { |prefix| path.start_with?(prefix) } }
    end

    # --force removes the untracked runtime copies. dirty? has already
    # refused any other change.
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

    def self.pairs(out)
      out.lines(chomp: true).slice_before { |line| line.start_with?("p") }
         .map { |group| [group.first[1..].to_i, group.find { |line| line.start_with?("n") }.to_s[1..].to_s] }
    end
  end
end
