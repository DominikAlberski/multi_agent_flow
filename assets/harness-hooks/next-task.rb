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
#   {"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command",
#     "command":"ruby .maf/coordination/harness-hooks/next-task.rb"}]}]}}
# Codex uses the project .codex/hooks.json file.
#
# Only a registered maf start session can read the board.
require "json"
require "rbconfig"
require_relative "session-guard"

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError
  {}
end
exit 0 unless input.is_a?(Hash)
guard = MafSession::Guard.new(ENV, input)
exit 0 unless guard.authorized?
exit 0 if input["hook_event_name"] == "SessionStart" || ENV["COORD_DISPATCHED"]

role = ENV.fetch("COORD_ROLE")
output = IO.popen(ENV.to_h, [RbConfig.ruby, guard.coord, "next", role], err: File::NULL, &:read).to_s
exit 0 unless output.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)

$stdout.print JSON.generate(
  decision: "block",
  reason: "Unclaimed tasks exist for role #{role}. " \
          "Run coord inbox to read messages, then coord next to list tasks. " \
          "Claim the next task and complete it. When no tasks remain, stop."
)
