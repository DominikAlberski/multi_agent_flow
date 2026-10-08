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
    bootstrap: File.join(ROOT, "lib", "maf", "bootstrap.rb"),
    contract: File.join(ROOT, "assets", "agents-contract.md")
  }.freeze

  # bootstrap.rb decides whether an existing script is "ours" by these signature
  # strings. If a script's header drifts, bootstrap stops recognizing its own
  # file and refuses to update it. Keep each signature in both places.
  SCRIPTS = {
    "coord" => "coord - shared coordination layer",
    "dispatcher" => "dispatcher - task board and inbox monitor that starts one-shot agents.",
    "vault" => "vault - shared knowledge base watcher (graphify + Obsidian + MCP).",
    "dashboard" => "dashboard - local observability web UI for multi-agent coordination.",
    "analyst" => "analyst - ask a small model for token hints about one dispatched worker.",
    "git-hooks/pre-commit" => "commit-guard - git pre-commit hook for the multi-agent flow.",
    "doc-graph-refresh" => "doc-graph-refresh - rebuild the knowledge graph after a markdown change."
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

  # Prints the failure and returns false, so a check ends with `ok || fail_with(...)`.
  def fail_with(first, *details)
    warn "FAIL: #{first}", *details
    false
  end

  def check_udas
    expected = uda_lines(File.read(FILES[:taskrc]))
    actual = uda_lines(coord_block)
    expected == actual || fail_with("UDA blocks differ", "  assets/taskrc.append: #{expected.inspect}",
                                    "  assets/coord:         #{actual.inspect}")
  end

  def check_markers
    missing = FILES.reject { |_, path| File.read(path).include?(MARKER) }
    missing.empty? || fail_with("marker '#{MARKER}' missing in: #{missing.keys.join(", ")}")
  end

  def check_no_duplicate_block
    !File.read(FILES[:bootstrap]).include?("TASKRC_BLOCK") ||
      fail_with("lib/maf/bootstrap.rb defines TASKRC_BLOCK; it must read taskrc.append")
  end

  def check_script_signatures
    bootstrap = File.read(FILES[:bootstrap])
    bad = SCRIPTS.reject { |name, signature| signed?(File.join(ROOT, "assets", name), signature, bootstrap) }
    bad.empty? || fail_with("script signature missing in the asset or lib/maf/bootstrap.rb: #{bad.keys.join(", ")}")
  end

  def signed?(path, signature, bootstrap)
    File.exist?(path) && File.read(path).include?(signature) && bootstrap.include?(signature)
  end

CHECKS = %i[check_udas check_markers check_no_duplicate_block check_script_signatures].freeze

  def run
    ok = check_files_exist && CHECKS.map { |name| send(name) }.all?
    puts(ok ? "check: OK" : "check: FAILED")
    exit(ok ? 0 : 1)
  end
end

Check.run
