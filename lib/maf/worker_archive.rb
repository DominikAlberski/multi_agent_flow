# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Maf
  # WorkerArchive moves the state of a retired worker into
  # .maf/coordination/archive/workers/<worker>-<time>-<random>/. A new worker
  # with the same id then starts clean: no old session to resume, no old
  # handoff note, no old status on the dashboard.
  class WorkerArchive
    def initialize(root, worker)
      @coord_dir = File.join(root, ".maf", "coordination")
      @worker = worker
    end

    def run
      sources = paths.select { |path, _name| File.exist?(path) }
      return if sources.empty?

      destination = archive_dir
      sources.each { |path, name| move(path, File.join(destination, name)) }
    end

    private

    def paths
      { File.join(@coord_dir, "inbox", @worker) => "inbox",
        File.join(@coord_dir, "usage", "#{@worker}.json") => "usage.json",
        File.join(@coord_dir, "status", "#{@worker}.json") => "status.json" }.merge(session_files)
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
