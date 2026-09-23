#!/usr/bin/env ruby
# frozen_string_literal: true

# check.rb - repo consistency checks for the multi-agent flow.
#
# Run: ruby scripts/check.rb
#
# The Taskwarrior UDA block is defined twice on purpose: assets/coord is copied
# into projects and cannot read assets/taskrc.append at runtime. This check keeps
# the two definitions in sync so a missing UDA cannot silently degrade into a
# Taskwarrior description suffix (which happened once with `worker`).
require "fileutils"

abort "check: Ruby 3.0+ required (current: #{RUBY_VERSION})." if RUBY_VERSION.split(".").first.to_i < 3

module Check
  ROOT = File.expand_path("..", __dir__)
  MARKER = ">>> multi-agent-flow >>>"
  UDA = /\Auda\.[a-z_]+\.type=string\z/

  FILES = {
    coord: File.join(ROOT, "assets", "coord"),
    taskrc: File.join(ROOT, "assets", "taskrc.append"),
    bootstrap: File.join(ROOT, "assets", "bootstrap.rb"),
    gitignore: File.join(ROOT, "assets", "gitignore.append"),
    contract: File.join(ROOT, "assets", "agents-contract.md")
  }.freeze

  # The worktree path is computed in two standalone scripts (coord creates the
  # worktree, setup_agent finds it again) that share no load path, so the
  # formula is duplicated on purpose. Keep the two identical.
  WORKTREE_FILES = {
    coord: File.join(ROOT, "assets", "coord"),
    setup_agent: File.join(ROOT, "assets", "setup_agent")
  }.freeze
  WORKTREE_SUFFIX_DEF = 'WORKTREES_DIR = ".worktrees"'
  WORKTREE_DIR_EXPR = 'File.join(root, WORKTREES_DIR, slug)'

  # bootstrap.rb decides whether an existing script is "ours" by these signature
  # strings. If a script's header drifts, bootstrap stops recognizing its own
  # file and refuses to update it. Keep each signature in both places.
  SCRIPTS = {
    "coord" => "coord - shared coordination layer",
    "setup_agent" => "setup_agent - create a worktree for one agent and launch its harness session.",
    "dispatcher" => "dispatcher - outside-of-agent message board monitor and agent spawner.",
    "vault" => "vault - shared knowledge base watcher (graphify + Obsidian + MCP).",
    "dashboard" => "dashboard - local observability web UI for multi-agent coordination."
  }.freeze

  module_function

  def check_files_exist
    missing = FILES.reject { |_, path| File.exist?(path) }
    return true if missing.empty?

    warn "FAIL: expected file missing: #{missing.values.join(", ")}"
    false
  end

  def uda_lines(text)
    text.lines.map(&:strip).select { |line| line.match?(UDA) }.sort
  end

  def coord_block
    match = File.read(FILES[:coord])[/TASKRC_BLOCK = <<~BLOCK\n(.*?)\n\s*BLOCK\b/m, 1]
    abort "check: cannot find TASKRC_BLOCK in assets/coord" unless match

    match
  end

  def check_udas
    expected = uda_lines(File.read(FILES[:taskrc]))
    actual = uda_lines(coord_block)
    return true if expected == actual

    warn "FAIL: UDA blocks differ"
    warn "  assets/taskrc.append: #{expected.inspect}"
    warn "  assets/coord:         #{actual.inspect}"
    false
  end

  def check_markers
    missing = FILES.reject { |_, path| File.read(path).include?(MARKER) }
    return true if missing.empty?

    warn "FAIL: marker '#{MARKER}' missing in: #{missing.keys.join(", ")}"
    false
  end

  def check_no_duplicate_block
    return true unless File.read(FILES[:bootstrap]).include?("TASKRC_BLOCK")

    warn "FAIL: assets/bootstrap.rb defines TASKRC_BLOCK; it must read taskrc.append"
    false
  end

  def check_worktree_paths
    bad = WORKTREE_FILES.reject do |_, path|
      next false unless File.exist?(path)

      text = File.read(path)
      text.include?(WORKTREE_SUFFIX_DEF) && text.include?(WORKTREE_DIR_EXPR)
    end
    return true if bad.empty?

    warn "FAIL: worktree path definition out of sync in: #{bad.keys.join(", ")}"
    false
  end

  def check_script_signatures
    bootstrap = File.read(FILES[:bootstrap])
    bad = SCRIPTS.reject do |name, signature|
      path = File.join(ROOT, "assets", name)
      File.exist?(path) && File.read(path).include?(signature) && bootstrap.include?(signature)
    end
    return true if bad.empty?

    warn "FAIL: script signature missing in the asset or assets/bootstrap.rb: #{bad.keys.join(", ")}"
    false
  end

  CHECKS = %i[check_udas check_markers check_no_duplicate_block check_worktree_paths
              check_script_signatures].freeze

  def run
    ok = check_files_exist && CHECKS.map { |name| send(name) }.all?
    puts(ok ? "check: OK" : "check: FAILED")
    exit(ok ? 0 : 1)
  end
end

Check.run
