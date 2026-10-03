# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Maf
  class WorkerArchive
    def initialize(root, worker)
      @coord_dir = File.join(root, ".maf", "coordination")
      @worker = worker
    end

    def run
      sources = paths.select { |path, _name| File.exist?(path) }
      return if sources.empty?

      destination = archive_dir
      sources.each { |path, name| FileUtils.mv(path, File.join(destination, name)) }
    end

    private

    def paths
      { File.join(@coord_dir, "inbox", @worker) => "inbox",
        File.join(@coord_dir, "usage", "#{@worker}.json") => "usage.json" }
    end

    def archive_dir
      parent = File.join(@coord_dir, "archive", "workers")
      FileUtils.mkdir_p(parent)
      Dir.mktmpdir("#{@worker}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-", parent)
    end
  end
end
