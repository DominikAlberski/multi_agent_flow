# frozen_string_literal: true

# migrate.rb - move an old-layout install of the multi-agent flow into .maf/.
#
# maf migrate runs Migrate::Runner. Options: --project DIR [--check] [--yes]
#
# Old layout: coord, dispatcher, vault, dashboard, coordination/, .worktrees/,
# graphify-out/, obsidian/, .agent-flow.json at the project root.
# New layout: everything in .maf/ (see USER_MANUAL.md).
#
# Moves files. Never deletes a file. Moves a script only if it carries the
# flow signature, and a role file only if it carries the marker. If the new
# path exists, the old file stays and the plan says so.
# After the moves, the runner regenerates the files of the current agents,
# like maf update.
require "fileutils"
require "json"
require "optparse"
require_relative "bootstrap"
require_relative "flow"
require_relative "env_exclude"

module Migrate
  # Step is one change. --check prints the label and runs nothing.
  Step = Struct.new(:label, :work) do
    def run = work.call
  end

  # The scripts of the old layout: [old path, new path, signature].
  SCRIPTS = [
    ["coord", ".maf/bin/coord", Bootstrap::COORD_SIGNATURE],
    ["dispatcher", ".maf/bin/dispatcher", Bootstrap::DISPATCHER_SIGNATURE],
    ["dashboard", ".maf/bin/dashboard", Bootstrap::DASHBOARD_SIGNATURE],
    ["vault", ".maf/bin/vault", Bootstrap::VAULT_SIGNATURE],
    ["vault-daemon", ".maf/bin/vault", Bootstrap::VAULT_SIGNATURE],
    ["coordination/doc-graph-refresh", ".maf/bin/doc-graph-refresh", Bootstrap::DOC_GRAPH_SIGNATURE]
  ].freeze

  # The folders of the old layout: [old path, new path].
  FOLDERS = [["coordination", ".maf/coordination"], ["graphify-out", ".maf/graphify-out"],
             ["obsidian", ".maf/obsidian"]].freeze

  HINT = "This project uses the old layout. Run: maf migrate"

  # True if the project has files of the old layout.
  def self.old_layout?(project)
    File.exist?(File.join(project, ".agent-flow.json")) ||
      File.exist?(File.join(project, "coordination", "taskrc")) ||
      SCRIPTS.any? { |old, _, signature| signed?(File.join(project, old), signature) }
  end

  def self.signed?(path, signature) = File.file?(path) && File.read(path).include?(signature)
end

require_relative "migrate/moves"
require_relative "migrate/worktrees"
require_relative "migrate/rewrites"
require_relative "migrate/role_files"
require_relative "migrate/runner"
