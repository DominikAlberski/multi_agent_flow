# frozen_string_literal: true

# setup_agent.rb - create a worktree for one agent and launch its harness session.
#
# Usage: maf start HARNESS ROLE[_WORKER] [model:MODEL] [--model MODEL]
#                  [--dispatch [DISPATCHER FLAGS...]]
#   maf start claude backend-developer_1
#   maf start opencode reviewer --model openrouter/deepseek-v3
#   maf start hermes tester --dispatch --model openrouter/deepseek-v3
#   maf start claude reviewer --dispatch --cache-window 1500
#
# Without --dispatch, the harness starts as an interactive session. With
# --dispatch, the worktree runs dispatcher instead: the agent starts only
# when there is work and exits when the work is done. Other flags after the
# positional arguments go to the dispatcher (for example --interval,
# --timeout, --cache-window). WORKER defaults to 1, or to "bot" with
# --dispatch, so a dispatched and an interactive instance of one role get
# separate worktrees. --detach (only with --dispatch) starts the dispatcher
# in the background, logs to .maf/coordination/sessions/<worker>.log, and records
# its pid in .maf/coordination/workers.json. `maf retire` stops it.
#
# HARNESS:ROLE must already exist in .maf/config.json (maf add HARNESS:ROLE
# adds one). Run from the project root.

require "json"
require "rbconfig"
require "fileutils"
require_relative "flow"
require_relative "workers"

abort "setup_agent: Ruby 3.0+ required (current: #{RUBY_VERSION})." if RUBY_VERSION.split(".").first.to_i < 3

module SetupAgent
  MANIFEST = ".maf/config.json"

  def self.run(argv)
    args = Args.parse(argv)
    manifest = Manifest.load(MANIFEST)
    manifest.verify!(args.harness, args.role)
    worktree = enter_worktree(args)
    register(args, manifest.model_for(args.harness, args.role))
    launch(args, manifest, worktree)
  end

  # `maf start` without arguments, inside a worktree that `maf prepare` made.
  def self.run_here
    root = Project.root
    entry = Maf::Workers.at(root).find(File.basename(Dir.pwd))
    abort "maf: #{Dir.pwd} is not a prepared worktree. Run: maf start HARNESS ROLE[_WORKER]" unless entry

    Dir.chdir(root)
    run(start_args(entry))
  end

  def self.start_args(entry)
    args = [entry["harness"], "#{entry["role"]}_#{entry["worker_id"]}"]
    args += ["--model", entry["model"]] if entry["model"]
    entry["dispatch"] ? args + ["--dispatch"] : args
  end

  def self.register(args, saved_model)
    entry = { "role" => args.role, "worker_id" => args.worker_id, "harness" => args.harness,
              "model" => args.model || saved_model, "dispatch" => args.dispatch, "dir" => Dir.pwd }
    Maf::Workers.at(Project.root).add(args.worker, entry.compact)
  end

  def self.enter_worktree(args)
    worktree = Worktree.ensure(args.role, args.worker_id, args.harness)
    RoleFile.copy(Dir.pwd, worktree.dir, args.harness, args.role)
    Dir.chdir(worktree.dir)
    worktree.export_env!
    worktree
  end

  def self.launch(args, manifest, _worktree)
    ENV["COORD_ROLE"] = args.role
    ENV["COORD_WORKER"] = args.worker
    model = args.model || manifest.model_for(args.harness, args.role)
    return Dispatch.launch(args, model) if args.dispatch

    # exec keeps this pid, so it is the harness pid. coord records it as the
    # worker's presence (.maf/coordination/presence/<worker>.json).
    ENV["COORD_SESSION_PID"] = Process.pid.to_s
    Launcher.for(args.harness).launch(args.role, args.worker, model)
  end
end

require_relative "setup_agent/args"
require_relative "setup_agent/dispatch"
require_relative "setup_agent/role_file"
require_relative "setup_agent/manifest"
require_relative "setup_agent/worktree"
require_relative "setup_agent/launcher"
require_relative "setup_agent/hermes_launcher"
require_relative "setup_agent/project"
require_relative "setup_agent/hermes_skill"
