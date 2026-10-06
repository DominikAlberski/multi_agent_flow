#!/usr/bin/env ruby
# frozen_string_literal: true

# next-task.rb - Stop hook for Claude Code and Codex.
#
# Fires each time the supervised agent stops. If unclaimed tasks exist for the
# agent's role, outputs a JSON block decision that injects a work prompt so the
# agent continues without a human turn. Exits 0 with no output when no tasks
# are available, letting the session end normally.
#
# After `coord await`, the hook first waits for work: see AwaitWork.
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

UUID_LINE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

def unclaimed_tasks?(guard, role)
  IO.popen(ENV.to_h, [RbConfig.ruby, guard.coord, "next", role], err: File::NULL, &:read).to_s.match?(UUID_LINE)
end

# AwaitWork serves `coord await`. The agent arms the hook and ends its turn.
# The hook then waits here, outside the model, until a waking message or a
# task arrives, or the wait ends. Codex has no watcher that wakes an idle
# session, and a wait inside a tool call returns to the model about every
# 30 seconds. This wait costs one model call at the end.
# NOTE: assets/coord writes the arm file and the FYI name mark.
class AwaitWork
  LEADS = %w[project-manager architect].freeze
  # Stay below the hook timeout that flow.rb sets for Codex (3600 seconds).
  MAX_SECONDS = 3300
  WOKE = "Work arrived for role %<role>s. Run coord inbox %<role>s. Then run coord next."
  QUIET = "No work arrived for role %<role>s in %<minutes>d minutes. Tell the user. " \
          "To wait again, run coord await and end your turn."

  def initialize(guard, role, worker)
    @guard, @role = guard, role
    @path = File.join(guard.coord_dir, "locks", "await-#{worker}.json")
  end

  def armed? = File.exist?(@path)

  def wait
    started, deadline = Time.now, disarm
    sleep tick until work? || Time.now >= deadline
    format(work? ? WOKE : QUIET, role: @role, minutes: ((Time.now - started) / 60).round)
  end

  private

  def disarm
    limit = JSON.parse(File.read(@path)).fetch("until", 0).to_i
    File.delete(@path)
    Time.at([limit, Time.now.to_i + MAX_SECONDS].min)
  rescue JSON::ParserError, SystemCallError
    Time.now
  end

  def tick = ENV.fetch("MAF_AWAIT_TICK", "10").to_f
  def work? = messages? || (!LEADS.include?(@role) && unclaimed_tasks?(@guard, @role))

  def messages?
    Dir.glob(File.join(@guard.coord_dir, "inbox", @role, "*.md")).any? { |path| !path.include?(".fyi.") }
  end
end

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
await = AwaitWork.new(guard, role, ENV.fetch("COORD_WORKER", role))
if await.armed?
  $stdout.print JSON.generate(decision: "block", reason: await.wait)
  exit 0
end
exit 0 unless unclaimed_tasks?(guard, role)

$stdout.print JSON.generate(
  decision: "block",
  reason: "Unclaimed tasks exist for role #{role}. " \
          "Run coord inbox to read messages, then coord next to list tasks. " \
          "Claim the next task and complete it. When no tasks remain, stop."
)
