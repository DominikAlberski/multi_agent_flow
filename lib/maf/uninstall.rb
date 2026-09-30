# frozen_string_literal: true

# uninstall.rb - remove the multi-agent flow from a project.
#
# maf uninstall runs Uninstall::Runner. Options: --project DIR [--check] [--yes] [--force]
#
# Removes only what bootstrap.rb and flow.rb installed. A file must carry the
# tool signature or marker. A foreign file with the same name stays.
# Keeps graphify-out/ and obsidian/. Rebuilding them costs many agent runs,
# so the user deletes them by hand.
# Keeps worker/* branches. Keeps dirty worktrees unless --force is given.
# Keeps the global Codex and Hermes hooks. Other projects can use them.
require "fileutils"
require "json"
require "optparse"
require_relative "bootstrap"
require_relative "flow"

module Uninstall
  KEPT_DIRS = %w[graphify-out obsidian].freeze

  # Removed after all steps if empty. Children come before parents.
  EMPTY_DIRS = [%w[.claude agents], %w[.claude], %w[.opencode agents], %w[.opencode plugins], %w[.opencode],
                %w[.codex prompts], %w[.codex], %w[.worktrees]].freeze

  GLOBAL_HOOKS = [File.join(Dir.home, ".codex", "hooks", "next-task.rb"),
                  File.join(Dir.home, ".hermes", "agent-hooks", "next-task.sh")].freeze

  # Step is one removal. --check prints the label and runs nothing.
  Step = Struct.new(:label, :work) do
    def run = work.call
  end
end

require_relative "uninstall/owned"
require_relative "uninstall/git"
require_relative "uninstall/vault_watcher"
require_relative "uninstall/worktrees"
require_relative "uninstall/scripts"
require_relative "uninstall/commit_guard"
require_relative "uninstall/doc_graph_hooks"
require_relative "uninstall/manifest"
require_relative "uninstall/role_files"
require_relative "uninstall/claude_settings"
require_relative "uninstall/marked_files"
require_relative "uninstall/coordination"
require_relative "uninstall/notes"
require_relative "uninstall/runner"
