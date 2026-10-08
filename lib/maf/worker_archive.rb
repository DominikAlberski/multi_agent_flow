# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Maf
  # WorkerArchive moves the state of a worker into
  # .maf/coordination/archive/workers/<worker>-<time>-<random>/. A new worker
  # with the same id then starts clean: no old session to resume, no old
  # handoff note, no old status or token data on the dashboard.
  class WorkerArchive
    def initialize(root, worker)
      @coord_dir = File.join(root, ".maf", "coordination")
      @worker = worker
    end

    def run = move_all({ File.join(@coord_dir, "inbox", @worker) => "inbox" }.merge(run_state, session_files))

    # A new harness cannot resume the session of the old harness, and its
    # token data must not add to the old data. The worker keeps its work: the
    # inbox, the handoff note, and the logs stay.
    def harness_change = move_all(run_state.merge(session_file))

    private

    def move_all(paths)
      sources = paths.select { |path, _name| File.exist?(path) }
      destination = archive_dir unless sources.empty?
      sources.each { |path, name| move(path, File.join(destination, name)) }
    end

    # The token data, the run history, the analyst hints, and the status.
    def run_state
      { File.join(@coord_dir, "usage", "#{@worker}.json") => "usage.json",
        File.join(@coord_dir, "usage", "#{@worker}.runs.jsonl") => "usage.runs.jsonl",
        File.join(@coord_dir, "hints", "#{@worker}.json") => "hints.json",
        File.join(@coord_dir, "status", "#{@worker}.json") => "status.json" }
    end

    def session_file
      path = File.join(@coord_dir, "sessions", "#{@worker}.session")
      { path => File.join("sessions", File.basename(path)) }
    end

    # The session id, the handoff note, the logs, and the watcher state.
    def session_files
      Dir.glob(File.join(@coord_dir, "sessions", "#{@worker}.*")).to_h do |path|
        [path, File.join("sessions", File.basename(path))]
      end
    end

    def move(path, dest)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.mv(path, dest)
    end

    def archive_dir
      parent = File.join(@coord_dir, "archive", "workers")
      FileUtils.mkdir_p(parent)
      Dir.mktmpdir("#{@worker}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-", parent)
    end
  end
end
