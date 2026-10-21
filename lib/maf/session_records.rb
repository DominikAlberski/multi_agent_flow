# frozen_string_literal: true

# session_records.rb - the live sessions that maf start registered.
require "json"
require "time"
require_relative "shared/processes"

module Maf
  # SessionRecords reads .maf/coordination/sessions/*.maf.json. The session
  # guard writes one record for each maf start. A record is live while its pid
  # runs and the process started before the record was written, so a reused
  # pid does not count.
  class SessionRecords
    LSTART = "%a %b %d %H:%M:%S %Y %z"

    def initialize(coord_dir)
      @dir = File.join(coord_dir, "sessions")
    end

    def live = Dir.glob(File.join(@dir, "*.maf.json")).filter_map { |path| entry(path) }
    def find(worker) = live.find { |record| record["worker"] == worker }

    private

    def entry(path)
      record = JSON.parse(File.read(path))
      started = Shared::Processes.started_at(record["pid"])
      record.merge("started" => started) if live?(record["pid"], started, File.mtime(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def live?(pid, started, registered)
      Shared::Processes.alive?(pid) && !started.empty? && Time.strptime("#{started} +0000", LSTART) <= registered
    rescue ArgumentError
      false
    end
  end
end
