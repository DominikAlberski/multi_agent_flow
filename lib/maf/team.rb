# frozen_string_literal: true

# team.rb - add, replace, and retire workers in one command.
#
#   maf prepare HARNESS ROLE[_WORKER] [--model M] [--dispatch | --interactive] [--replace WORKER]
#   maf retire WORKER
#
# The project manager runs these commands. `maf prepare` adds the role file,
# creates the worktree, and registers the worker. With --dispatch, it also
# starts the dispatcher in the background. Without --dispatch, the user runs
# two commands: `cd <worktree>` and `maf start`. The architect is dispatched
# unless --interactive is given.
require "rbconfig"
require_relative "setup_agent"
require_relative "workers"
require_relative "retire"
require_relative "budget"

module Maf
  module Team
    def self.coord(root, *args, env: {})
      IO.popen(env, [RbConfig.ruby, File.join(root, ".maf", "bin", "coord"), *args], chdir: root, err: File::NULL, &:read).to_s
    end

    def self.notify(root, text) = coord(root, "msg", "--from", "maf", "architect", text)
  end

  # Prepare makes a worker ready to start. With --replace, it retires the
  # old worker, so the old worker's tasks return to the pool. If the old and
  # the new worker have the same id (only the harness or the model changes),
  # the worker keeps its worktree and its claims.
  class Prepare
    # The architect never talks to the user. A dispatched architect gets fresh
    # sessions with a handoff note, so its context stays small.
    DISPATCH_DEFAULT = %w[architect].freeze

    def self.mode_args(argv)
      return argv - ["--interactive"] if argv.include?("--interactive")

      role = SetupAgent::Args.split_role(argv[1].to_s).first
      DISPATCH_DEFAULT.include?(role) && !argv.include?("--dispatch") ? argv + ["--dispatch"] : argv
    end

    def initialize(argv)
      @replace = take_replace(argv)
      @args = SetupAgent::Args.parse(self.class.mode_args(argv))
      @root = SetupAgent::Project.root
      @budget = Budget.at(@root)
      @args.model ||= @budget.default_model(@args.harness)
    end

    def run
      @budget.check!(@args.harness, @args.model, @budget.count(workers_after))
      retire = @replace && Retire.new(@root, @replace)
      retire&.check!
      Dir.chdir(@root) { prepare }
      retire.run if retire && Workers.id(@replace) != @args.worker
      Team.notify(@root, "Team change: worker #{@args.worker} (#{@args.harness}) joined as #{@args.role}.")
      @args.dispatch ? start_dispatcher : print_next_steps
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

    def workers_after
      all = Workers.at(@root).all
      all = all.except(Workers.id(@replace)) if @replace
      all.merge(@args.worker => { "role" => @args.role })
    end

    # SetupAgent.run changes into the worktree, so it runs after prepare.
    def start_dispatcher
      Dir.chdir(@root)
      args = [@args.harness, "#{@args.role}_#{@args.worker_id}", "--dispatch", "--detach"]
      SetupAgent.run(@args.model ? args + ["--model", @args.model] : args)
    end

    def entry(dir)
      { "role" => @args.role, "worker_id" => @args.worker_id, "harness" => @args.harness,
        "model" => @args.model, "dispatch" => @args.dispatch, "dir" => dir }.compact
    end

    def print_next_steps
      dir = SetupAgent::Worktree.dir_for(@root, @args.worker)
      puts "", "Worker #{@args.worker} is ready. Run in a new terminal:", "  cd #{dir}", "  maf start"
    end
  end
end
