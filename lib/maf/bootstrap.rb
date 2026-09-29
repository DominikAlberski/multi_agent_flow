#!/usr/bin/env ruby
# frozen_string_literal: true

# bootstrap.rb - install the multi-agent coordination layer into a project.
# flow.rb runs this file as a subprocess.
#
# Usage:
#   ruby lib/maf/bootstrap.rb /path/to/project [--roles architect,backend-developer,...]
#                                   [--check] [--install-deps] [--force]
#
# Idempotent: every file change is marker-guarded or content-compared, so
# re-running never duplicates blocks and never reinstalls what is present.
# Ruby:     3.0+ (same as coord).
require "fileutils"
require "json"
require "optparse"

abort "bootstrap: Ruby 3.0+ required (current: #{RUBY_VERSION}). Install with " \
      "mise/brew: `brew install mise && mise install ruby`." if RUBY_VERSION.split(".").first.to_i < 3

module Bootstrap
  MARKER = ">>> multi-agent-flow >>>"
  END_MARKER = "<<< multi-agent-flow <<<"
  COORD_SIGNATURE = "coord - shared coordination layer"
  # Older installs copied setup_agent into the project. uninstall.rb removes it.
  SETUP_AGENT_SIGNATURE = "setup_agent - create a worktree for one agent and launch its harness session."
  DISPATCHER_SIGNATURE = "dispatcher - task board and inbox monitor that starts one-shot agents."
  VAULT_SIGNATURE = "vault - shared knowledge base watcher (graphify + Obsidian + MCP)."
  DASHBOARD_SIGNATURE = "dashboard - local observability web UI for multi-agent coordination."
  SUBDIRS = %w[inbox locks exports message-hooks harness-hooks].freeze

  NEXT_TASK_HOOK_SIGNATURE = "next-task.rb - Stop hook for Claude Code and Codex."
  NEXT_TASK_HERMES_SIGNATURE = "next-task-hermes.sh - on_session_end hook for Hermes Agent."
  BOARD_WATCH_SIGNATURE = "board-watch.rb - background board watcher for Claude Code sessions."
  COMMIT_GUARD_SIGNATURE = "commit-guard - git pre-commit hook for the multi-agent flow."

  # Claude Code harness hooks: [event, hook]. The sync next-task hook continues
  # a session at Stop. The asyncRewake board-watch hook wakes an idle session.
  CLAUDE_HOOKS = [
    ["Stop", { "type" => "command", "command" => "ruby coordination/harness-hooks/next-task.rb" }],
    *%w[SessionStart Stop].map do |event|
      [event, { "type" => "command", "command" => "ruby coordination/harness-hooks/board-watch.rb",
                "async" => true, "asyncRewake" => true, "timeout" => 604_800 }]
    end
  ].freeze

  PLAN_STEPS = %i[plan_coordination_dirs plan_gitkeeps plan_coord plan_dispatcher
                  plan_vault plan_dashboard plan_taskrc plan_claude_md plan_contracts plan_gitignore
                  plan_hook_scripts plan_claude_stop_hook plan_commit_guard].freeze

  # Project instruction files that stop Claude Code from reading AGENTS.md.
  CLAUDE_MD_FILES = ["CLAUDE.md", File.join(".claude", "CLAUDE.md")].freeze

  # Maps each writing action kind to the Installer method that performs it.
  # Every writer takes (path, source). :skip and :refuse write nothing.
  WRITERS = { mkdir: :make_dir, touch: :touch_file, create: :write_script, update: :write_script,
              create_taskrc: :write_taskrc, upgrade_taskrc: :upgrade_taskrc,
              append: :append_marked, replace: :replace_marked, move_claude_md: :move_claude_md,
              configure_claude_hook: :configure_claude_settings }.freeze

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

      2. Set COORD_ROLE and COORD_WORKER so messages and locks are attributed, e.g.:
           export COORD_ROLE=local COORD_WORKER=local-1

      3. Shared memory (graphify + Obsidian vault): %{vault_note}

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
      @assets = File.expand_path("../../assets", __dir__)
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
      auto_start_vault(actions)
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
      return install_dep(bin, meta) if @install_deps && !@check

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
      PLAN_STEPS.flat_map { |step| send(step) }
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

    def plan_dispatcher
      plan_script("dispatcher", DISPATCHER_SIGNATURE)
    end

    def plan_dashboard
      plan_script("dashboard", DASHBOARD_SIGNATURE)
    end

    def plan_vault
      @vault_script_name = File.directory?(File.join(@target, "vault")) ? "vault-daemon" : "vault"
      dest = File.join(@target, @vault_script_name)
      status = script_status(dest, "vault", VAULT_SIGNATURE)
      label = if status == :refuse
                "#{dest} (exists and is not ours; use --force)"
              elsif @vault_script_name == "vault-daemon"
                "#{dest} (vault/ is a directory; installing as vault-daemon instead)"
              else
                dest
              end
      action(status, dest, label, "vault")
    end

    def plan_script(name, signature)
      dest = File.join(@target, name)
      status = script_status(dest, name, signature)
      label = status == :refuse ? "#{dest} (exists and is not ours; use --force)" : dest
      action(status, dest, label, name)
    end

    def script_status(dest, name, signature)
      return :create unless File.exist?(dest)
      return :refuse if File.directory?(dest)
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
      status = taskrc_status(path)
      label = if status == :refuse
                "#{path} (exists and is not ours; use --force)"
              else
                "#{path} (Taskwarrior UDAs, project-local)"
              end
      action(status, path, label)
    end

    # Never overwrite a taskrc this tool did not create: it may point at a
    # real Taskwarrior database. A marked taskrc from an older install that
    # has no data.location is upgraded in place, not rewritten.
    def taskrc_status(path)
      return :create_taskrc unless File.exist?(path)
      return :create_taskrc if @force && !ours?(path, MARKER)
      return :refuse unless ours?(path, MARKER)
      return :skip if has_data_location?(path)

      :upgrade_taskrc
    end

    def has_data_location?(path)
      File.read(path).match?(/^data\.location=/)
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

    # Claude Code reads AGENTS.md only when the project has no CLAUDE.md.
    # Move each CLAUDE.md into AGENTS.md, so every harness reads one file.
    def plan_claude_md
      CLAUDE_MD_FILES.map { |name| File.join(@target, name) }.select { |path| File.file?(path) }
                     .map { |path| action(:move_claude_md, path, "#{path} (move into AGENTS.md)") }
    end

    # AGENTS.md is the only instruction file. Every harness reads it.
    def plan_contracts
      path = File.join(@target, "AGENTS.md")
      [action(block_status(path, :contract), path, "#{path} (agent contract)", :contract)]
    end

    def plan_gitignore
      path = File.join(@target, ".gitignore")
      action(block_status(path, :gitignore), path, "#{path} (ignore rules)", :gitignore)
    end

    def plan_hook_scripts
      [
        ["harness-hooks/next-task.rb", File.join(@target, "coordination", "harness-hooks", "next-task.rb"),
         NEXT_TASK_HOOK_SIGNATURE],
        ["harness-hooks/next-task-hermes.sh", File.join(@target, "coordination", "harness-hooks", "next-task-hermes.sh"),
         NEXT_TASK_HERMES_SIGNATURE],
        ["harness-hooks/board-watch.rb", File.join(@target, "coordination", "harness-hooks", "board-watch.rb"),
         BOARD_WATCH_SIGNATURE]
      ].map do |src_name, dest, signature|
        status = hook_script_status(dest, src_name, signature)
        label = status == :refuse ? "#{dest} (exists and is not ours; use --force)" : dest
        action(status, dest, label, src_name)
      end
    end

    def hook_script_status(dest, src_name, signature)
      return :create unless File.exist?(dest)
      return :refuse if !ours?(dest, signature) && !@force
      return :skip if ours?(dest, signature) && !changed_script?(dest, src_name)

      :update
    end

    COMMIT_GUARD = "git-hooks/pre-commit"

    # The commit guard blocks commits by roles with can_edit false. A foreign
    # pre-commit hook stays, even with --force: it may run the project checks.
    def plan_commit_guard
      dest = commit_guard_path
      return [] unless dest

      status = commit_guard_status(dest)
      label = status == :refuse ? "#{dest} (a foreign pre-commit hook; the commit guard is off)" : dest
      [action(status, dest, label, COMMIT_GUARD)]
    end

    def commit_guard_status(dest)
      return :create unless File.exist?(dest)
      return :refuse unless ours?(dest, COMMIT_GUARD_SIGNATURE)

      changed_script?(dest, COMMIT_GUARD) ? :update : :skip
    end

    def commit_guard_path
      hooks = IO.popen(["git", "-C", @target, "rev-parse", "--git-path", "hooks"], err: File::NULL, &:read).strip
      $?.success? && !hooks.empty? ? File.join(File.expand_path(hooks, @target), "pre-commit") : nil
    end

    def plan_claude_stop_hook
      return [] unless Dir.exist?(File.join(@target, ".claude"))

      path = File.join(@target, ".claude", "settings.json")
      status = claude_hook_status(path)
      [action(status, path, "#{path} (next-task + board-watch hooks)", :claude_stop_hook)]
    end

    def claude_hook_status(path)
      return :configure_claude_hook unless File.exist?(path)

      settings = JSON.parse(File.read(path)) rescue {}
      claude_hook_present?(settings) ? :skip : :configure_claude_hook
    end

    def claude_hook_present?(settings)
      missing_claude_hooks(settings).empty?
    end

    def missing_claude_hooks(settings)
      CLAUDE_HOOKS.reject { |event, hook| claude_hook_entry?(settings, event, hook["command"]) }
    end

    def claude_hook_entry?(settings, event, command)
      (settings.dig("hooks", event) || []).any? { |entry| entry.dig("hooks", 0, "command") == command }
    end

    def configure_claude_settings(path, _source = nil)
      settings = File.exist?(path) ? (JSON.parse(File.read(path)) rescue {}) : {}
      missing = missing_claude_hooks(settings)
      missing.each { |event, hook| add_claude_hook(settings, event, hook) }
      write_json(path, settings) unless missing.empty?
      !missing.empty?
    end

    def add_claude_hook(settings, event, hook)
      settings["hooks"] ||= {}
      (settings["hooks"][event] ||= []) << { "matcher" => "", "hooks" => [hook] }
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data))
    end

    # A marked block is owned by this tool. When the shipped block changed
    # (new ignore rules, new commands in the contract), replace the old block
    # in place so existing installs pick it up. Text outside the block stays.
    def block_status(path, source)
      return :append unless marked?(path)

      MarkedBlock.new(File.read(path)).current?(append_content(source)) ? :skip : :replace
    end

    def action(kind, path, label = path, source = nil)
      { kind: kind, path: path, label: label, source: source }
    end

    def apply(actions)
      actions.each { |a| apply_action(a) }
    end

    def apply_action(a)
      writer = WRITERS[a[:kind]]
      return say(format_action(a)) unless writer

      send(writer, a[:path], a[:source]) && say("done   #{a[:label]}")
    end

    def make_dir(path, _source)
      FileUtils.mkdir_p(path)
    end

    def touch_file(path, _source)
      FileUtils.touch(path)
    end

    # Auto-start the vault watcher once the script is in place, so shared
    # memory is live right after install with no extra step for the common
    # case (graphify already installed). Skipped when graphify is missing;
    # the printed next steps cover installing it and running `./vault` later.
    def auto_start_vault(actions)
      return @vault_note = "skipped (VAULT_SKIP is set)" if ENV["VAULT_SKIP"]
      script = @vault_script_name || "vault"
      return @vault_note = "run `./#{script}` after bootstrap (graphify not needed at install time, only to run it)" \
        unless vault_script_installed?(actions)
      return @vault_note = "run `./#{script}` once graphify is installed" unless which("graphify")

      start_vault
    end

    def vault_script_installed?(actions)
      script = @vault_script_name || "vault"
      actions.any? { |a| a[:path] == File.join(@target, script) && a[:kind] != :refuse }
    end

    def start_vault
      script = @vault_script_name || "vault"
      ok = system(File.join(@target, script), chdir: @target)
      cmd = "./#{script}"
      @vault_note = ok ? "started (`#{cmd} status` / `#{cmd} stop`)" : "failed to start; see coordination/vault.log"
      say("vault: #{@vault_note}")
    end

    def format_action(a)
      case a[:kind]
      when :skip   then "skip   #{a[:label]}"
      when :refuse then "REFUSE #{a[:label]}"
      when :upgrade_taskrc then "upgrade #{a[:label]}"
      else "#{a[:kind]} #{a[:label]}"
      end
    end

    def write_script(dest, name)
      src = File.join(@assets, name)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(src, dest)
      FileUtils.chmod("+x", dest)
      true
    end

    def write_taskrc(path, _source = nil)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(taskdata_path)
      File.write(path, "data.location=#{taskdata_path}\n\n#{append_content(:taskrc)}")
      true
    end

    # Add the missing data.location to a taskrc this tool already owns,
    # without touching the rest of the file. An old marked taskrc without it
    # would otherwise fall back to the user's global ~/.task.
    def upgrade_taskrc(path, _source = nil)
      FileUtils.mkdir_p(taskdata_path)
      File.open(path, "a") do |file|
        file.puts unless file.size.zero?
        file.puts("data.location=#{taskdata_path}")
      end
      true
    end

    def append_marked(path, source)
      FileUtils.touch(path)
      File.open(path, "a") { |file| file.puts; file.write(append_content(source)); file.puts }
      true
    end

    # Drops the old contract block and any `@AGENTS.md` import: AGENTS.md
    # gets its own contract, and a self-import is a loop.
    def move_claude_md(path, _source = nil)
      text = MarkedBlock.new(File.read(path)).remove.lines.reject { |line| line.strip == "@AGENTS.md" }.join.strip
      append_text(File.join(@target, "AGENTS.md"), text) unless text.empty?
      FileUtils.rm(path)
    end

    def append_text(path, text)
      old = File.exist?(path) ? File.read(path).rstrip : ""
      File.write(path, [old, text].reject(&:empty?).join("\n\n") + "\n")
    end

    def replace_marked(path, source)
      File.write(path, MarkedBlock.new(File.read(path)).replace(append_content(source)))
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
      puts format(NEXT_STEPS, project: @target, roles: @roles, vault_note: @vault_note)
    end
  end

  # MarkedBlock finds the tool-owned block in a file: from the first line that
  # contains MARKER to the next line that contains END_MARKER, inclusive. The
  # comment syntax around the markers differs per file (`#` vs `<!-- -->`), so
  # only the marker text is matched.
  class MarkedBlock
    def initialize(text)
      @lines = text.lines
    end

    def current?(block)
      range && @lines[range].join.strip == block.strip
    end

    def replace(block)
      return @lines.join unless range

      block = "#{block.chomp}\n"
      (@lines[0...range.begin] + [block] + @lines[(range.end + 1)..]).join
    end

    def remove
      return @lines.join unless range

      (@lines[0...range.begin] + @lines[(range.end + 1)..]).join
    end

    private

    def range
      @range ||= find_range
    end

    def find_range
      first = @lines.index { |line| line.include?(MARKER) }
      last = first && @lines[first..].index { |line| line.include?(END_MARKER) }
      last && (first..(first + last))
    end
  end
end

Bootstrap::Installer.new(ARGV).run if __FILE__ == $PROGRAM_NAME
