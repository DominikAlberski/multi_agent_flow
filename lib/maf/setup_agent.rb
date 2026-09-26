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
# --dispatch, the worktree runs ./dispatcher instead: the agent starts only
# when there is work and exits when the work is done. Other flags after the
# positional arguments go to the dispatcher (for example --interval,
# --timeout, --cache-window). WORKER defaults to 1, or to "bot" with
# --dispatch, so a dispatched and an interactive instance of one role get
# separate worktrees. --detach (only with --dispatch) starts the dispatcher
# in the background, logs to coordination/sessions/<worker>.log, and records
# its pid in coordination/workers.json. `maf retire` stops it.
#
# HARNESS:ROLE must already exist in .agent-flow.json (maf add HARNESS:ROLE
# adds one). Run from the project root.

require "json"
require "rbconfig"
require "fileutils"
require_relative "flow"
require_relative "workers"

abort "setup_agent: Ruby 3.0+ required (current: #{RUBY_VERSION})." if RUBY_VERSION.split(".").first.to_i < 3

module SetupAgent
  MANIFEST = ".agent-flow.json"

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

    Launcher.for(args.harness).launch(args.role, args.worker, model)
  end

  # Args reads the positional arguments (HARNESS ROLE[_WORKER] [model:M]),
  # then the flags. --dispatch and --model M are setup_agent's own flags; all
  # other flags go to the dispatcher and need --dispatch.
  class Args
    Parsed = Struct.new(:harness, :role, :worker_id, :worker, :model, :dispatch, :detach, :dispatcher_args,
                        keyword_init: true)

    def self.parse(argv)
      dispatch, detach, positional, flags = split(argv)
      model = take_model(flags)
      reject_stray(flags, dispatch)
      abort "setup_agent: --detach works only with --dispatch" if detach && !dispatch
      Parsed.new(**identity(positional, model, dispatch), dispatch: dispatch, detach: detach, dispatcher_args: flags)
    end

    def self.split(argv)
      rest = argv - %w[--dispatch --detach]
      index = rest.index { |arg| arg.start_with?("--") } || rest.size
      [argv.include?("--dispatch"), argv.include?("--detach"), rest[0...index], rest[index..-1]]
    end

    def self.identity(positional, model, dispatch)
      harness, role_spec, model_arg = positional
      abort_usage if harness.nil? || role_spec.nil?
      role, worker_id = split_role(role_spec, dispatch ? "bot" : "1")
      { harness: harness, role: role, worker_id: worker_id, worker: "#{role}-#{worker_id}",
        model: model || model_arg&.sub(/\Amodel:/, "") }
    end

    def self.take_model(flags)
      index = flags.index("--model")
      value = index && flags.slice!(index, 2)[1]
      abort "setup_agent: --model needs a value" if index && (value.nil? || value.start_with?("--"))
      value
    end

    def self.reject_stray(flags, dispatch)
      return if flags.empty? || dispatch

      abort "setup_agent: #{flags.join(" ")} works only with --dispatch"
    end

    def self.split_role(spec, default_id = "1")
      role, _sep, worker_id = spec.rpartition("_")
      role.empty? ? [spec, default_id] : [role, worker_id]
    end

    def self.abort_usage
      abort "usage: maf start HARNESS ROLE[_WORKER] [model:MODEL] [--model MODEL] [--dispatch [FLAGS...]]"
    end
  end

  # Dispatch runs ./dispatcher in the worktree instead of an interactive
  # session. The worktree's own copy of the dispatcher is used, so the
  # project must have committed it. The current Ruby runs it, so an old
  # system Ruby on the shebang path never parses it.
  module Dispatch
    def self.launch(args, model)
      require_dispatcher!
      cmd = [RbConfig.ruby, "./dispatcher", args.role, "--harness", args.harness]
      cmd += ["--model", model] if model
      cmd += args.dispatcher_args
      args.detach ? detach(cmd, args.worker) : Launcher.exec_or_die(cmd)
    end

    # setsid gives the dispatcher its own session, so it keeps running when
    # the terminal or the harness session that started it ends.
    def self.detach(cmd, worker)
      log = File.join(ENV.fetch("COORD_DIR"), "sessions", "#{worker}.log")
      pid = spawn_detached(cmd, log)
      Maf::Workers.at(Project.root).update(worker, "pid" => pid)
      puts "Started #{worker} in the background (pid #{pid}). Log: #{log}"
    end

    def self.spawn_detached(cmd, log)
      FileUtils.mkdir_p(File.dirname(log))
      io = { in: File::NULL, out: [log, "a"], err: %i[child out] }
      pid = fork { Process.setsid && exec({ "DISPATCHER_LOG" => log }, *cmd, **io) }
      Process.detach(pid) && pid
    end

    def self.require_dispatcher!
      return if File.exist?("dispatcher")

      main = ENV["COORD_DIR"] ? File.dirname(File.expand_path(ENV["COORD_DIR"])) : nil
      hint = main ? "\n  Fix:\n    cd #{main}\n    git add dispatcher && git commit -m 'Add dispatcher'\n  Then re-run setup_agent." \
                  : " Commit dispatcher from your main project directory first, then re-run."
      abort "setup_agent: dispatcher missing in this worktree (worktrees only contain committed files).#{hint}"
    end
  end

  # A role file that is not committed yet is missing in a new worktree, and
  # the harness then starts without its role. Copy the main checkout's file.
  module RoleFile
    def self.copy(root, dir, harness, role)
      relative = Flow.role_path(harness, role)
      source = relative && File.join(root, relative)
      return unless source && File.exist?(source) && !File.exist?(File.join(dir, relative))

      FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
      FileUtils.cp(source, File.join(dir, relative))
    end
  end

  class Manifest
    def self.load(path)
      abort_missing(path) unless File.exist?(path)

      new(JSON.parse(File.read(path))["agents"])
    end

    def self.abort_missing(path)
      abort "setup_agent: #{path} missing. Fix: maf add HARNESS:ROLE"
    end

    def initialize(agents)
      @agents = agents
    end

    def verify!(harness, role)
      return if @agents.any? { |a| a["harness"] == harness && a["role"] == role }

      abort "setup_agent: no #{harness}:#{role} in .agent-flow.json.\n#{add_hint("#{harness}:#{role}")}"
    end

    # maf add keeps the current agents, so the hint names only the missing agent.
    def add_hint(missing) = "  Fix: maf add #{missing}"

    def model_for(harness, role)
      entry = @agents.find { |a| a["harness"] == harness && a["role"] == role }
      entry && entry["model"]
    end
  end

  class Worktree
    # All worktrees live inside the project under .worktrees/<slug>.
    # This must match Coord::Worktree.dir_for; scripts/check.rb enforces it.
    WORKTREES_DIR = ".worktrees"

    def self.dir_for(root, slug)
      File.join(root, WORKTREES_DIR, slug)
    end

    # `coord worktree` is idempotent. Run it also for an existing worktree,
    # so the worktree gets runtime files that were added after it was created.
    # MAF_HARNESS tells coord which harness starts the worker, so coord checks
    # the role file of that harness only.
    def self.ensure(role, worker_id, harness)
      dir = dir_for(Dir.pwd, "#{role}-#{worker_id}")
      abort "setup_agent: ./coord worktree failed" unless system({ "MAF_HARNESS" => harness }, "./coord", "worktree", role, worker_id)
      new(dir)
    end

    def initialize(dir)
      @dir = dir
    end

    def dir
      @dir
    end

    def export_env!
      path = File.join(@dir, "coord-env.sh")
      File.readlines(path).each { |line| set_env(line) } if File.exist?(path)
    end

    private

    def set_env(line)
      return unless line.chomp =~ /\Aexport (\w+)=(.+)\z/

      ENV[Regexp.last_match(1)] = Regexp.last_match(2)
    end
  end

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
        prompt = "Read .claude/agents/#{role}.md and follow it exactly. Start your work loop now."
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

    # Hermes loads role files as skills from <hermes_dir>/<project>-<role>/.
    # flow.rb writes the skill there; --skills <project>-<role> loads it.
    # Hermes has no --agent flag; the skill's SKILL.md is the role definition.
    # `-q` on a TTY seeds an interactive session with the prompt.
    module Hermes
      PROMPT = "Follow the multi-agent coordination rules in AGENTS.md as role %<role>s. " \
               "Run ./coord inbox, then ./coord next --wait. Claim a task, do the work, finish it. Repeat."

      def self.launch(role, _worker, model)
        cmd = %w[hermes chat]
        cmd += ["--skills", HermesSkill.name(role)] if HermesSkill.installed?(role)
        cmd += ["--model", model] if model
        Launcher.exec_or_die(cmd + ["-q", format(PROMPT, role: role)])
      end
    end
  end

  # Project finds the main checkout from any worktree. `git rev-parse
  # --git-common-dir` returns the main repo's .git dir (relative at the root,
  # absolute in a worktree), so its parent is the main checkout.
  # NOTE: dispatcher carries the same logic; both run standalone.
  module Project
    def self.root
      common = IO.popen(%w[git rev-parse --git-common-dir], err: File::NULL, &:read).to_s.strip
      common.empty? ? Dir.pwd : File.dirname(File.expand_path(common))
    end

    def self.manifest
      JSON.parse(File.read(File.join(root, MANIFEST)))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
  end

  # HermesSkill resolves the skill flow.rb generated for a role: the name is
  # <project>-<role>, and the dir is the manifest's hermes_dir (set by
  # `flow.rb --hermes-dir`) or flow.rb's default ~/.hermes/skills.
  module HermesSkill
    DEFAULT_DIR = File.join(Dir.home, ".hermes", "skills")

    # Plain defs, not endless ones: this file must still parse on Ruby 2.x so
    # the version check above can print its message.
    def self.name(role)
      "#{File.basename(Project.root)}-#{role}"
    end

    def self.dir
      Project.manifest.fetch("hermes_dir", DEFAULT_DIR)
    end

    def self.installed?(role)
      File.exist?(File.join(dir, name(role), "SKILL.md"))
    end
  end
end
