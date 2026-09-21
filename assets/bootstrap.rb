#!/usr/bin/env ruby
# frozen_string_literal: true

# bootstrap.rb - install the multi-agent coordination layer into a project.
#
# Usage:
#   ./bootstrap.rb /path/to/project [--roles architect,backend-developer,...]
#                                   [--check] [--install-deps] [--force]
#
# Idempotent: every file change is marker-guarded or content-compared, so
# re-running never duplicates blocks and never reinstalls what is present.
require "fileutils"
require "optparse"

module Bootstrap
  MARKER = ">>> multi-agent-flow >>>"
  COORD_SIGNATURE = "coord - shared coordination layer"
  SETUP_AGENT_SIGNATURE = "setup_agent - create a worktree for one agent and launch its harness session."
  SUBDIRS = %w[inbox locks exports].freeze

  REQUIRED_DEPS = {
    "task" => {
      why: "Taskwarrior, the task board backend",
      install: -> { system("brew", "install", "task") }
    }
  }.freeze

  OPTIONAL_DEPS = {
    "graphify" => "knowledge graph (pip/uv install graphifyy)"
  }.freeze

  NEXT_STEPS = <<~TEXT
    Next steps (run inside %{project}):

      1. Verify:
           cd %{project} && ./coord init && ./coord status

      2. Set COORD_AGENT so messages and locks are attributed, e.g.:
           export COORD_AGENT=local

      3. Shared memory (optional, needs graphify):
           graphify . --obsidian --obsidian-dir vault --watch --mcp

      4. Serialize local generation on the shared model host:
           ./coord with-lock ollama -- <command>

    Requested roles: %{roles}

    The task board lives in %{project}/coordination/taskdata (project-local),
    not in your global Taskwarrior database. Point `task` at it directly with:
      TASKRC=%{project}/coordination/taskrc task ...
  TEXT

  MIGRATION_NOTE = <<~TEXT

    [multi-agent-flow] NOTE: found the multi-agent-flow UDA block in your
    global %{taskrc}. Older versions of this installer shared one Taskwarrior
    database across every project. This install now uses a project-local
    database instead (%{project}/coordination/taskdata) and does not touch
    %{taskrc}.

    Tasks already in the global database are NOT moved automatically. To
    bring old tasks into this project:
      TASKRC=%{taskrc} task export project:%{project_name} > /tmp/old-tasks.json
      TASKRC=%{project}/coordination/taskrc task import /tmp/old-tasks.json
    (adjust the `project:` filter to however the old tasks are tagged.)
  TEXT

  class Installer
    def initialize(argv)
      @argv = argv
      @assets = __dir__
      @target = nil
      @roles = "architect,backend-developer,frontend-developer,reviewer,tester"
      @check = false
      @install_deps = false
      @force = false
      parse
    end

    def run
      validate_target
      report_dependencies
      warn_global_taskrc
      actions = plan
      return print_plan(actions) if @check

      apply(actions)
      print_next_steps
    end

    private

    def parse
      option_parser.parse!(@argv)
      @target = @argv.first
    end

    def option_parser
      OptionParser.new do |o|
        o.banner = "Usage: bootstrap.rb /path/to/project [--roles a,b,c] [--check] [--install-deps] [--force]"
        o.on("--roles LIST") { |v| @roles = v }
        o.on("--check") { @check = true }
        o.on("--install-deps") { @install_deps = true }
        o.on("--force") { @force = true }
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end

    def print_plan(actions)
      actions.each { |action| say format_action(action) }
      puts "\n--check: no changes made."
    end

    def validate_target
      abort "usage: bootstrap.rb /path/to/project [--roles a,b,c] [--check] [--force]" if @target.nil?
      abort "target is not a directory: #{@target}" unless Dir.exist?(@target)
      @target = File.realpath(@target)
    end

    def report_dependencies
      report_required
      report_optional
    end

    def report_required
      REQUIRED_DEPS.each { |bin, meta| report_required_dep(bin, meta) }
    end

    def report_required_dep(bin, meta)
      return say("#{bin}: present") if which(bin)
      return install_dep(bin, meta) if @install_deps

      say("#{bin}: MISSING (required - #{meta[:why]}). Re-run with --install-deps or install it yourself.")
    end

    def install_dep(bin, meta)
      say("#{bin}: missing -> installing (#{meta[:why]})")
      meta[:install].call || abort("bootstrap: failed to install #{bin}")
    end

    def report_optional
      OPTIONAL_DEPS.each { |bin, hint| say("#{bin}: #{which(bin) ? "present" : "missing (optional - #{hint})"}") }
    end

    def plan
      [
        plan_coordination_dirs,
        plan_gitkeeps,
        plan_coord,
        plan_setup_agent,
        plan_taskrc,
        plan_contracts,
        plan_gitignore
      ].flatten
    end

    def plan_coordination_dirs
      SUBDIRS.map do |sub|
        path = File.join(@target, "coordination", sub)
        action(Dir.exist?(path) ? :skip : :mkdir, path)
      end
    end

    def plan_gitkeeps
      SUBDIRS.map do |sub|
        path = File.join(@target, "coordination", sub, ".gitkeep")
        action(File.exist?(path) ? :skip : :touch, path)
      end
    end

    def plan_coord
      plan_script("coord", COORD_SIGNATURE)
    end

    def plan_setup_agent
      plan_script("setup_agent", SETUP_AGENT_SIGNATURE)
    end

    def plan_script(name, signature)
      dest = File.join(@target, name)
      status = script_status(dest, name, signature)
      label = status == :refuse ? "#{dest} (exists and is not ours; use --force)" : dest
      action(status, dest, label, name)
    end

    def script_status(dest, name, signature)
      return :create unless File.exist?(dest)
      return :refuse if !ours?(dest, signature) && !@force
      return :skip if ours?(dest, signature) && !changed_script?(dest, name)

      :update
    end

    def ours?(path, signature)
      File.read(path).include?(signature)
    end

    def changed_script?(dest, name)
      File.read(dest) != File.read(File.join(@assets, name))
    end

    def plan_taskrc
      path = taskrc_path
      action(marked?(path) ? :skip : :create_taskrc, path, "#{path} (Taskwarrior UDAs, project-local)")
    end

    def taskrc_path
      File.join(@target, "coordination", "taskrc")
    end

    def taskdata_path
      File.join(@target, "coordination", "taskdata")
    end

    # Earlier versions of this installer appended the UDA block to the user's
    # global ~/.taskrc, sharing one Taskwarrior database across every project.
    # Warn instead of silently leaving old tasks stranded there.
    def warn_global_taskrc
      global = ENV.fetch("TASKRC", File.join(Dir.home, ".taskrc"))
      return unless File.exist?(global) && File.read(global).include?(MARKER)
      return if same_file?(global, taskrc_path)

      puts format(MIGRATION_NOTE, taskrc: global, project: @target, project_name: File.basename(@target))
    end

    def same_file?(a, b)
      File.exist?(a) && File.exist?(b) && File.identical?(a, b)
    end

    # AGENTS.md is harness-agnostic and always created. CLAUDE.md is
    # Claude-Code-specific: only touch it if it already exists (a Claude Code
    # user, or `flow.rb`, created it first). Don't add a file irrelevant to a
    # project that isn't using Claude Code.
    def plan_contracts
      files = [File.join(@target, "AGENTS.md")]
      files << File.join(@target, "CLAUDE.md") if File.exist?(File.join(@target, "CLAUDE.md"))
      files.map { |f| action(marked?(f) ? :skip : :append, f, "#{f} (agent contract)", :contract) }
    end

    def plan_gitignore
      path = File.join(@target, ".gitignore")
      action(marked?(path) ? :skip : :append, path, "#{path} (ignore rules)", :gitignore)
    end

    def action(kind, path, label = path, source = nil)
      { kind: kind, path: path, label: label, source: source }
    end

    def apply(actions)
      actions.each do |a|
        case a[:kind]
        when :skip   then say "skip   #{a[:label]}"
        when :refuse then say "REFUSE #{a[:label]}"
        when :mkdir  then FileUtils.mkdir_p(a[:path]) && say("done   #{a[:label]}")
        when :touch  then FileUtils.touch(a[:path]) && say("done   #{a[:label]}")
        when :create, :update then write_script(a[:path], a[:source]) && say("done   #{a[:label]}")
        when :create_taskrc then write_taskrc(a[:path]) && say("done   #{a[:label]}")
        when :append then append_marked(a[:path], a[:source]) && say("done   #{a[:label]}")
        end
      end
    end

    def format_action(a)
      case a[:kind]
      when :skip   then "skip   #{a[:label]}"
      when :refuse then "REFUSE #{a[:label]}"
      else "#{a[:kind]} #{a[:label]}"
      end
    end

    def write_script(dest, name)
      src = File.join(@assets, name)
      FileUtils.cp(src, dest)
      FileUtils.chmod("+x", dest)
      true
    end

    def write_taskrc(path)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(taskdata_path)
      File.write(path, "data.location=#{taskdata_path}\n\n#{append_content(:taskrc)}")
      true
    end

    def append_marked(path, source)
      FileUtils.touch(path)
      File.open(path, "a") { |file| file.puts; file.write(append_content(source)); file.puts }
      true
    end

    def append_content(source)
      files = { taskrc: "taskrc.append", contract: "agents-contract.md", gitignore: "gitignore.append" }
      File.read(File.join(@assets, files.fetch(source)))
    end

    def marked?(path)
      File.exist?(path) && File.read(path).include?(MARKER)
    end

    def which(bin)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, bin))
      end
    end

    def say(message)
      puts "[multi-agent-flow] #{message}"
    end

    def print_next_steps
      puts
      puts format(NEXT_STEPS, project: @target, roles: @roles)
    end
  end
end

Bootstrap::Installer.new(ARGV).run
