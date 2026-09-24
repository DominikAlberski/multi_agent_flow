#!/usr/bin/env ruby
# frozen_string_literal: true

# next-task.rb - Stop hook for Claude Code and Codex.
#
# Fires each time the supervised agent stops. If unclaimed tasks exist for the
# agent's role, outputs a JSON block decision that injects a work prompt so the
# agent continues without a human turn. Exits 0 with no output when no tasks
# are available, letting the session end normally.
#
# Claude Code (.claude/settings.json):
#   {"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"ruby coordination/harness-hooks/next-task.rb"}]}]}}
# Codex (~/.codex/hooks.json):
#   {"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"ruby ~/.codex/hooks/next-task.rb"}]}]}}
#
# Required env: COORD_ROLE (set by setup_agent). COORD_DIR and TASKRC optional.
require "json"
require "rbconfig"

role = ENV["COORD_ROLE"].to_s
exit 0 if role.empty? || role == "unknown"

coord_dir = ENV.fetch("COORD_DIR", "coordination")
taskrc    = ENV.fetch("TASKRC", File.join(coord_dir, "taskrc"))

coord = [
  File.join(Dir.pwd, "coord"),
  File.join(File.expand_path("..", coord_dir), "coord")
].find { |p| File.executable?(p) }
exit 0 unless coord

env = ENV.to_h.merge(
  "TASKRC"       => taskrc,
  "COORD_DIR"    => coord_dir,
  "COORD_ROLE"   => role,
  "COORD_WORKER" => ENV.fetch("COORD_WORKER", role)
)
output = IO.popen(env, [RbConfig.ruby, coord, "next", role], err: File::NULL, &:read).to_s
exit 0 unless output.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)

$stdout.print JSON.generate(
  decision: "block",
  reason: "Unclaimed tasks exist for role #{role}. " \
          "Run ./coord inbox to read messages, then ./coord next to list tasks. " \
          "Claim the next task and complete it. When no tasks remain, stop."
)
