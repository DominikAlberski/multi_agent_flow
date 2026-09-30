# frozen_string_literal: true

# flow.rb - generate harness-specific role files for the multi-agent flow.
#
# maf add, maf remove, maf update, and maf roles run Flow::Generator.
# Options: --project DIR [--agent HARNESS:ROLE ...] [--remove HARNESS:ROLE ...]
#          [--model ROLE=MODEL] [--hermes-dir DIR] [--check] [--force] [--no-bootstrap]
#          [--list-roles]
#
# HARNESS is one of: opencode, claude, codex, hermes.
# A re-run keeps the agents in .agent-flow.json. --agent adds an agent.
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

abort "flow: Ruby 3.0+ required (current: #{RUBY_VERSION})." if RUBY_VERSION.split(".").first.to_i < 3

module Flow
  ROOT = File.expand_path("../..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")
  ASSETS = File.join(ROOT, "assets")
  HARNESSES = %w[opencode claude codex hermes].freeze
  DEFAULT_HERMES_DIR = File.join(Dir.home, ".hermes", "skills")

  # Model a harness gets when neither --agent nor --model names one.
  # Other harnesses have no safe default, so their CLI picks the model.
  DEFAULT_MODELS = { "claude" => "claude-opus-5-5" }.freeze

  # Roles that dispatch or coordinate instead of implementing. They are never
  # advertised as dispatch targets in the architect prompt.
  LEADS = %w[project-manager architect].freeze
  DISPATCH_EXCLUDE = LEADS

  # Hermes toolsets for a role with can_edit false: no file, code_execution,
  # or delegation toolset. The shell stays, because the role needs ./coord and git.
  # NOTE: assets/dispatcher carries the same list; both run standalone.
  READ_ONLY_TOOLSETS = "terminal,web,skills,todo,memory,session_search,clarify"

  PROJECT_ROLE_PATHS = { "opencode" => ".opencode/agents/%s.md", "claude" => ".claude/agents/%s.md",
                         "codex" => ".codex/prompts/%s.md" }.freeze

  # The role file path inside the project. Hermes keeps role files outside
  # the project, so it has no path here.
  def self.role_path(harness, role)
    template = PROJECT_ROLE_PATHS[harness]
    template && format(template, role)
  end
end

require_relative "flow/prompt_text"
require_relative "flow/hermes_hook"
require_relative "flow/roster"
require_relative "flow/options"
require_relative "flow/prompt_builder"
require_relative "flow/hook_files"
require_relative "flow/hermes_hook_setup"
require_relative "flow/hook_installer"
require_relative "flow/role_files"
require_relative "flow/manifest"
require_relative "flow/report"
require_relative "flow/generator"
