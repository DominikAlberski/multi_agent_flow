# frozen_string_literal: true

# worker_list.rb - list the workers that run now: sessions and dispatchers.
require "json"
require "time"
require_relative "workers"
require_relative "shared/processes"

module Maf
  # WorkerList shows each running worker process of the project. A worker
  # can run twice, for example as a session and as a dispatcher.
  class WorkerList
    Row = Struct.new(:worker, :role, :harness, :mode, :pid, :started)
    HEADER = %w[WORKER ROLE HARNESS MODE PID STARTED].freeze
    LSTART = "%a %b %d %H:%M:%S %Y %z"

    def initialize(root)
      @root = root
      @workers = Workers.at(root)
    end

    def run
      rows = running
      puts rows.empty? ? "No worker runs." : table([HEADER] + rows.map { |row| row.to_a.map(&:to_s) }), warnings(rows)
    end

    private

    def running = (sessions + dispatchers + registered).uniq(&:pid).sort_by { |row| [row.worker, row.mode] }

    def coord_dir = File.join(@root, ".maf", "coordination")
    def records(dir, pattern) = Dir.glob(File.join(coord_dir, dir, pattern)).map { |path| [path, read(path)] }

    def sessions
      records("sessions", "*.maf.json").filter_map do |path, record|
        row(record, "session") if session_live?(record["pid"], File.mtime(path))
      end
    end

    def session_live?(pid, registered)
      started = Shared::Processes.started_at(pid)
      Shared::Processes.alive?(pid) && !started.empty? && Time.strptime("#{started} +0000", LSTART) <= registered
    rescue ArgumentError
      false
    end

    def dispatchers
      records("presence", "*.json").filter_map do |_, entry|
        row(entry, "dispatch") if entry["mode"] == "dispatch" && Shared::Processes.live?(entry)
      end
    end

    def registered
      @workers.all.filter_map do |worker, entry|
        row(entry.merge("worker" => worker), "dispatch") if @workers.dispatcher?(worker)
      end
    end

    def row(data, mode)
      entry = @workers.find(data["worker"]).to_h
      Row.new(data["worker"], data["role"] || entry["role"], data["harness"] || entry["harness"], mode,
              data["pid"].to_i, Shared::Processes.started_at(data["pid"]))
    end

    def table(lines)
      widths = lines.transpose.map { |column| column.map(&:size).max }
      lines.map { |line| line.zip(widths).map { |text, width| text.ljust(width) }.join("  ").rstrip }
    end

    def warnings(rows)
      twice = rows.group_by(&:worker).select { |_, list| list.size > 1 }
      stopped = @workers.all.keys - rows.map(&:worker)
      twice.map { |worker, list| "warning: #{worker} runs #{list.size} times (pids #{list.map(&:pid).join(", ")})" } +
        (stopped.empty? ? [] : ["stopped: #{stopped.join(", ")}"])
    end

    def read(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      {}
    end
  end
end
