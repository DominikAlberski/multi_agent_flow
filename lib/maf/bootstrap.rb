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
  # The one folder in the project that holds every file of the flow.
  MAF_DIR = ".maf"
  COORD_SIGNATURE = "coord - shared coordination layer"
  # Older installs copied setup_agent into the project. uninstall.rb removes it.
  SETUP_AGENT_SIGNATURE = "setup_agent - create a worktree for one agent and launch its harness session."
  DISPATCHER_SIGNATURE = "dispatcher - task board and inbox monitor that starts one-shot agents."
  VAULT_SIGNATURE = "vault - shared knowledge base watcher (graphify + Obsidian + MCP)."
  DASHBOARD_SIGNATURE = "dashboard - local observability web UI for multi-agent coordination."
  ANALYST_SIGNATURE = "analyst - ask a small model for token hints about one dispatched worker."
  # The scripts in .maf/bin load the shared library from .maf/lib/maf/shared/.
  # Its source is lib/maf/shared/. The installer gives paths relative to assets/.
  SHARED_DIR = File.join("lib", "maf", "shared")
  SHARED_SOURCE = File.join("..", SHARED_DIR)
  SHARED_SIGNATURE = "maf shared library - code that the maf CLI and the scripts in .maf/bin share."
  SUBDIRS = %w[inbox locks exports message-hooks harness-hooks].freeze

  NEXT_TASK_HOOK_SIGNATURE = "next-task.rb - Stop hook for Claude Code and Codex."
  NEXT_TASK_HERMES_SIGNATURE = "next-task-hermes.sh - on_session_end hook for Hermes Agent."
  BOARD_WATCH_SIGNATURE = "board-watch.rb - background board watcher for Claude Code sessions."
  SESSION_GUARD_SIGNATURE = "session-guard.rb - authorize hooks for a registered MAF session."
  CONTEXT_WATCH_SIGNATURE = "context-watch.rb - status, usage, and context limit hook"
  OPENCODE_BOARD_WATCH_SIGNATURE = "board-watch-opencode.js - opencode plugin that wakes an idle session"
  OPENCODE_PLUGIN = File.join(".opencode", "plugins", "board-watch.js")
  COMMIT_GUARD_SIGNATURE = "commit-guard - git pre-commit hook for the multi-agent flow."
  DOC_GRAPH_SIGNATURE = "doc-graph-refresh - rebuild the knowledge graph after a markdown change."
  ENV_SIGNATURE = "env.sh - shell environment of the multi-agent flow."

  # Claude Code harness hooks: [event, hook]. The sync next-task hook continues
  # a session at Stop. The asyncRewake board-watch hook wakes an idle session.
  CLAUDE_HOOKS = [
    ["SessionStart", { "type" => "command", "command" => "ruby .maf/coordination/harness-hooks/next-task.rb" }],
    ["Stop", { "type" => "command", "command" => "ruby .maf/coordination/harness-hooks/next-task.rb" }],
    *%w[SessionStart Stop].map do |event|
      [event, { "type" => "command", "command" => "ruby .maf/coordination/harness-hooks/context-watch.rb" }]
    end,
    *%w[SessionStart Stop].map do |event|
      [event, { "type" => "command", "command" => "ruby .maf/coordination/harness-hooks/board-watch.rb",
                "async" => true, "asyncRewake" => true, "timeout" => 604_800 }]
    end
  ].freeze

  # The paths that every install excludes from git. AgentLinks and CodexHooks
  # add the harness paths they create.
  EXCLUDED = [".maf/", OPENCODE_PLUGIN].freeze

  # The Claude Code settings of the flow. `maf start` passes them with --settings,
  # so the project's .claude/settings.json stays as it is.
  CLAUDE_SETTINGS = File.join(MAF_DIR, "claude", "settings.json")

  # Maps each writing action kind to the Installer method that performs it.
  # Every writer takes (path, source). :skip and :refuse write nothing.
  WRITERS = { mkdir: :make_dir, touch: :touch_file, create: :write_script, update: :write_script,
              create_taskrc: :write_taskrc, upgrade_taskrc: :upgrade_taskrc,
              local_exclude: :write_exclude,
              configure_claude_hook: :configure_claude_settings, merge_hook: :merge_hook }.freeze

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
           cd %{project} && source .maf/env.sh && coord init && coord status

      2. Set COORD_ROLE and COORD_WORKER so messages and locks are attributed, e.g.:
           export COORD_ROLE=local COORD_WORKER=local-1

      3. Shared memory (graphify + Obsidian vault): %{vault_note}

      4. Serialize local generation on the shared model host:
           coord with-lock ollama -- <command>

    Requested roles: %{roles}

    The task board lives in %{project}/.maf/coordination/taskdata (project-local),
    not in your global Taskwarrior database. Point `task` at it directly with:
      TASKRC=%{project}/.maf/coordination/taskrc task ...
  TEXT

  MIGRATION_NOTE = <<~TEXT

    [multi-agent-flow] NOTE: found the multi-agent-flow UDA block in your
    global %{taskrc}. Older versions of this installer shared one Taskwarrior
    database across every project. This install now uses a project-local
    database instead (%{project}/.maf/coordination/taskdata) and does not touch
    %{taskrc}.

    Tasks already in the global database are NOT moved automatically. To
    bring old tasks into this project:
      TASKRC=%{taskrc} task export project:%{project_name} > /tmp/old-tasks.json
      TASKRC=%{project}/.maf/coordination/taskrc task import /tmp/old-tasks.json
    (adjust the `project:` filter to however the old tasks are tagged.)
  TEXT

  def self.say(message)
    puts "[multi-agent-flow] #{message}"
  end

  def self.which(bin)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, bin)) }
  end
end

require_relative "local_exclude"
require_relative "bootstrap/marked_block"
require_relative "bootstrap/options"
require_relative "bootstrap/dependencies"
require_relative "bootstrap/project"
require_relative "bootstrap/global_taskrc_warning"
require_relative "bootstrap/layout_planner"
require_relative "bootstrap/script_planner"
require_relative "bootstrap/git_hook_planner"
require_relative "bootstrap/text_planner"
require_relative "bootstrap/claude_settings"
require_relative "bootstrap/hook_merger"
require_relative "bootstrap/writer"
require_relative "bootstrap/vault_starter"
require_relative "bootstrap/installer"

Bootstrap::Installer.new(ARGV).run if __FILE__ == $PROGRAM_NAME
