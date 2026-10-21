# frozen_string_literal: true

# flow.rb - generate harness-specific role files for the multi-agent flow.
#
# maf add, maf remove, maf update, and maf roles run Flow::Generator.
# Options: --project DIR [--agent HARNESS:ROLE ...] [--remove HARNESS:ROLE ...]
#          [--model ROLE=MODEL] [--effort ROLE=LEVEL] [--hermes-dir DIR] [--check] [--force] [--no-bootstrap]
#          [--list-roles]
#
# HARNESS is a harness of the registry: one file in lib/maf/shared/harnesses/.
# A re-run keeps the agents in .maf/config.json. --agent adds an agent.
# --remove drops an agent. Without --agent, a re-run regenerates the current agents.
# Idempotent: identical files are skipped, changed files are updated, and
# foreign files are refused unless --force is given.
require "fileutils"
require "yaml"
require "erb"
require "json"
require "optparse"
require "rbconfig"
require "time"
require_relative "shared/roles"
require_relative "shared/harness"

abort "flow: Ruby 3.0+ required (current: #{RUBY_VERSION})." if RUBY_VERSION.split(".").first.to_i < 3

module Maf
  module Flow
    ROOT = File.expand_path("../..", __dir__)
    TEMPLATES = File.join(ROOT, "templates")
    ASSETS = File.join(ROOT, "assets")
    # The registry of the harnesses. Each harness is one file in lib/maf/shared/harnesses/.
    Harness = Maf::Shared::Harness

    # Roles that dispatch or coordinate instead of implementing. They are never
    # advertised as dispatch targets in the architect prompt.
    LEADS = Maf::Shared::Roles::LEADS
    DISPATCH_EXCLUDE = LEADS

    MAF_DIR = ".maf"
  end
end

require_relative "local_exclude"
require_relative "flow/prompt_text"
require_relative "flow/hermes_hook"
require_relative "flow/roster"
require_relative "flow/role_catalog"
require_relative "flow/role_stub"
require_relative "flow/workflow"
require_relative "flow/options"
require_relative "flow/prompt_builder"
require_relative "flow/hook_files"
require_relative "flow/hermes_hook_setup"
require_relative "flow/hermes_env_setup"
require_relative "flow/codex_hooks"
require_relative "flow/legacy_codex_hook"
require_relative "flow/hook_installer"
require_relative "flow/agent_links"
require_relative "flow/mcp_config"
require_relative "flow/mcp_installer"
require_relative "flow/role_files"
require_relative "flow/manifest"
require_relative "flow/models"
require_relative "flow/effort_report"
require_relative "flow/report"
require_relative "flow/validator"
require_relative "flow/harness_linker"
require_relative "flow/bootstrapper"
require_relative "flow/generator"
