# frozen_string_literal: true

# uninstall.rb - remove the multi-agent flow from a project.
#
# maf uninstall runs Uninstall::Runner. Options: --project DIR [--check] [--yes] [--force]
#
# Removes only what bootstrap.rb and flow.rb installed. A file must carry the
# tool signature or marker. A foreign file with the same name stays.
# Keeps graphify-out/ at the project root: the graph, the Obsidian vault, and
# the saved notes. Rebuilding the graph costs many agent runs, so the user deletes it by hand.
# Removes .maf/ if nothing is left in it.
# Keeps worker/* branches. Keeps dirty worktrees unless --force is given.
# Keeps the guarded global Hermes hook. Other projects can use the hook.
# Stops on an old layout. --check then prints the plan of maf migrate.
require "fileutils"
require "json"
require "optparse"
require_relative "bootstrap"
require_relative "flow"
require_relative "env_exclude"
require_relative "local_exclude"
require_relative "migrate"
require_relative "shared/sandbox"

module Maf
  # Uninstall removes the flow from a project. Each harness adds its own
  # folders, files, and cleaners (Maf::Shared::Harness).
  module Uninstall
    KEPT_DIRS = %w[graphify-out].freeze
    # The folders of the shared library in .maf/lib/. Children come before parents.
    LIB_DIRS = [*%w[harness harnesses sandbox].map { |dir| [".maf", "lib", "maf", "shared", dir] },
                %w[.maf lib maf shared], %w[.maf lib maf], %w[.maf lib]].freeze

    # Removed after all steps if empty. Children come before parents.
    def self.empty_dirs
      harnesses = Maf::Shared::Harness.all
      harnesses.flat_map(&:empty_dirs).map { |dir| dir.split("/") } + [%w[.maf bin]] +
        harnesses.map { |harness| [".maf", "agents", harness.name] } +
        [%w[.maf agents], %w[.maf worktrees], *LIB_DIRS, %w[.maf]]
    end

    # Files outside the project that uninstall keeps: other projects can use them.
    def self.global_files = Maf::Shared::Harness.all.flat_map(&:global_files)

    # The cleaners of each harness. untrack runs only the legacy cleaners.
    def self.harness_cleaners(project, legacy_only: false)
      Maf::Shared::Harness.all.flat_map { |h| h.legacy_cleaners(project) + (legacy_only ? [] : h.cleaners(project)) }
    end

    # Step is one removal. --check prints the label and runs nothing.
    Step = Struct.new(:label, :work) do
      def run = work.call
    end
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
require_relative "uninstall/codex_hooks"
require_relative "uninstall/mcp_entries"
require_relative "uninstall/marked_files"
require_relative "uninstall/coordination"
require_relative "uninstall/local_files"
require_relative "uninstall/notes"
require_relative "uninstall/vm_files"
require_relative "uninstall/runner"
