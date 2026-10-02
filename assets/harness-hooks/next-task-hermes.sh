#!/usr/bin/env ruby
# frozen_string_literal: true

# next-task-hermes.sh - on_session_end hook for Hermes Agent.
# Only a registered MAF session can resume the work loop.
require "json"
require "rbconfig"
require_relative "session-guard"

module HermesNextTask
  def self.run(input)
    return unless input.is_a?(Hash)

    guard = MafSession::Guard.new(ENV, input.merge("hook_event_name" => "SessionStart"))
    resume(guard, input) if !ENV["COORD_DISPATCHED"] && guard.authorized? && work?(guard)
  end

  def self.work?(guard)
    output = IO.popen(ENV.to_h, [RbConfig.ruby, guard.coord, "next", ENV.fetch("COORD_ROLE")],
                      err: File::NULL, &:read)
    output.match?(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)
  end

  def self.resume(guard, input)
    Process.detach(fork { start(guard, input) })
  end

  def self.start(guard, input)
    Process.setsid
    MafSession.register(File.dirname(File.dirname(guard.coord_dir)), "hermes")
    exec({ "HERMES_ACCEPT_HOOKS" => "1" }, *command(input), in: File::NULL, out: File::NULL, err: File::NULL)
  end

  def self.command(input)
    ["hermes", "chat", "--oneshot", "--yolo", "--accept-hooks", "--resume", input.fetch("session_id"), "-q", prompt]
  end

  def self.prompt
    "Unclaimed tasks exist for role #{ENV.fetch('COORD_ROLE')}. Run coord inbox, then coord next. " \
      "Claim and complete the next task. When no tasks remain, stop."
  end
end

begin
  HermesNextTask.run(JSON.parse($stdin.read))
rescue JSON::ParserError
  exit 0
end
