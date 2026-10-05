#!/usr/bin/env ruby
# frozen_string_literal: true

# context-watch.rb - status, usage, and context limit hook for interactive
# Claude Code and Codex sessions.
#
# Stop: the script reads the new part of the session transcript. It writes
# the model and the context size to .maf/coordination/status/<worker>.json,
# and adds the token usage to .maf/coordination/usage/<worker>.json. If the
# context is over the limit, it asks the agent one time for a handoff note.
# Then it tells the user to type /clear. Each model call sends the whole
# context again, so a fresh session with the note costs less.
#
# SessionStart: after /clear or a new start, the script gives the new session
# the handoff note as context.
#
# Limit: MAF_CONTEXT_LIMIT, else team.context_limit in .maf/config.json, else
# DEFAULT_LIMIT tokens. Only a registered maf start session runs the script.
# Dispatched agents (COORD_DISPATCHED) are skipped: the dispatcher owns them.
require "json"
require "fileutils"
require "time"
require_relative "session-guard"

module ContextWatch
  DEFAULT_LIMIT = 150_000
  ASK = "Your context has %<tokens>d tokens, over the limit of %<limit>d. Each model call sends the whole " \
        "context again. Overwrite %<path>s with a handoff note for your next session. Write at most 300 " \
        "words: current state, decisions, open questions, and the next step. Then stop."
  TELL = "Context: %<tokens>dk tokens (limit %<limit>dk). The handoff note is in %<path>s. " \
         "Type /clear to restart. The new session loads the note."

  # Reading is the new part of one transcript: model, context size, and usage.
  Reading = Struct.new(:model, :context, :window, :usage, :offset, :total)

  # Transcript reads the lines after OFFSET. Claude Code writes one line per
  # content block, with the same message id and usage, so ids are counted once.
  # Codex writes cumulative totals, so the usage is the change of the total.
  class Transcript
    USAGE_KEYS = %w[input_tokens cached_input_tokens output_tokens].freeze

    def initialize(path, offset, seen_total)
      @path, @offset, @seen_total = path, offset, seen_total
    end

    def read
      reading = Reading.new(nil, nil, nil, Hash.new(0), @offset, nil)
      lines { |event| claude(reading, event) || codex(reading, event) }
      reading.offset = File.size(@path)
      reading
    end

    private

    def lines
      File.open(@path) do |file|
        file.seek(@offset)
        file.each_line { |line| (event = parse(line)) && yield(event) }
      end
    end

    def parse(line)
      event = JSON.parse(line)
      event.is_a?(Hash) ? event : nil
    rescue JSON::ParserError
      nil
    end

    def claude(reading, event)
      usage = event.dig("message", "usage")
      return false unless event["type"] == "assistant" && usage && !event["isSidechain"]

      reading.model = event.dig("message", "model")
      reading.context = %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].sum { |k| usage[k].to_i }
      add_claude(reading, event.dig("message", "id"), usage)
    end

    def add_claude(reading, id, usage)
      return true if (@ids ||= {}).key?(id)

      @ids[id] = true
      reading.usage["input_tokens"] += reading.context
      reading.usage["cached_input_tokens"] += usage["cache_read_input_tokens"].to_i
      reading.usage["output_tokens"] += usage["output_tokens"].to_i
    end

    def codex(reading, event)
      payload = event["payload"] || {}
      reading.model = payload["model"] if event["type"] == "turn_context"
      info = payload["info"] if payload["type"] == "token_count"
      info && codex_tokens(reading, info)
    end

    def codex_tokens(reading, info)
      reading.context = info.dig("last_token_usage", "input_tokens")
      reading.window = info["model_context_window"]
      reading.total = (info["total_token_usage"] || {}).slice(*USAGE_KEYS)
      USAGE_KEYS.each { |key| reading.usage[key] = reading.total[key].to_i - @seen_total[key].to_i }
    end
  end

  # Store reads and writes the status and the usage files of one worker.
  class Store
    def initialize(coord_dir, worker)
      @status = File.join(coord_dir, "status", "#{worker}.json")
      @usage = File.join(coord_dir, "usage", "#{worker}.json")
      @handoff = File.join(coord_dir, "sessions", "#{worker}.handoff.md")
    end

    attr_reader :handoff

    def status = read(@status)
    def save(data) = write(@status, status.merge(data))
    def note = File.exist?(@handoff) ? File.read(@handoff).strip : ""

    def add_usage(delta)
      return if delta.values.all?(&:zero?)

      totals = read(@usage)
      sums = delta.to_h { |key, value| [key, totals[key].to_i + value] }
      write(@usage, totals.merge(sums).merge("runs" => totals["runs"].to_i + 1))
    end

    private

    def read(path)
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end

    def write(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write("#{path}.tmp", JSON.generate(data))
      File.rename("#{path}.tmp", path)
    end
  end

  # Hook handles one hook event and returns the JSON output, or nil.
  class Hook
    def initialize(input, env)
      @input, @env = input, env
      @store = Store.new(env.fetch("COORD_DIR"), env.fetch("COORD_WORKER"))
    end

    def run = @input["hook_event_name"] == "SessionStart" ? session_start : stop

    private

    def session_start
      @store.save("session_id" => @input["session_id"], "asked" => nil)
      note = @store.note
      return nil if note.empty?

      context = "Handoff note from your previous session (#{File.mtime(@store.handoff).utc.iso8601}):\n#{note}"
      { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: context } }
    end

    def stop
      path = @input["transcript_path"].to_s
      return nil unless File.exist?(path)

      same = @store.status["transcript"] == path
      seen = same ? @store.status["seen_total"] || {} : {}
      reading = Transcript.new(path, same ? @store.status["offset"].to_i : 0, seen).read
      record(path, reading)
      limit_output(@store.status["context_tokens"].to_i)
    end

    def record(path, reading)
      @store.add_usage(reading.usage)
      @store.save(status_fields(path, reading))
    end

    # A value that this read did not find keeps its last known value.
    def status_fields(path, reading)
      found = { "model" => reading.model, "context_tokens" => reading.context, "context_window" => reading.window,
                "seen_total" => reading.total }.compact
      { "mode" => "interactive", "role" => @env["COORD_ROLE"], "harness" => harness, "context_limit" => limit,
        "pid" => @env["COORD_SESSION_PID"]&.to_i, "transcript" => path, "offset" => reading.offset,
        "updated_at" => Time.now.utc.iso8601 }.merge(found)
    end

    # Codex keeps its transcripts in ~/.codex/sessions.
    def harness = @input["transcript_path"].to_s.include?("/.codex/") ? "codex" : "claude"

    def limit_output(tokens)
      return nil if tokens < limit
      return { systemMessage: format(TELL, tokens: tokens / 1000, limit: limit / 1000, path: @store.handoff) } if asked?

      @store.save("asked" => @input["session_id"])
      { decision: "block", reason: format(ASK, tokens: tokens, limit: limit, path: @store.handoff) }
    end

    def asked? = @store.status["asked"] == @input["session_id"]

    def limit
      value = @env["MAF_CONTEXT_LIMIT"] || manifest_limit || DEFAULT_LIMIT
      @limit ||= Integer(value, exception: false) || DEFAULT_LIMIT
    end

    def manifest_limit
      JSON.parse(File.read(File.join(@env.fetch("COORD_DIR"), "..", "config.json"))).dig("team", "context_limit")
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  input = begin
    JSON.parse($stdin.read)
  rescue JSON::ParserError
    {}
  end
  exit 0 if !input.is_a?(Hash) || ENV["COORD_DISPATCHED"] || !ENV["COORD_DIR"] || !ENV["COORD_WORKER"]
  exit 0 unless MafSession::Guard.new(ENV, input).authorized?

  output = ContextWatch::Hook.new(input, ENV).run
  $stdout.print(JSON.generate(output)) if output
end
