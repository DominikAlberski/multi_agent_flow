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

  CHECKS = %i[check_udas check_markers check_no_duplicate_block].freeze

  def run
    ok = check_files_exist && CHECKS.map { |name| send(name) }.all?
    puts(ok ? "check: OK" : "check: FAILED")
    exit(ok ? 0 : 1)
  end
end

Check.run
