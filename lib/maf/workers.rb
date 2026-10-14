# frozen_string_literal: true

# workers.rb - registry of the workers that run in this project.
#
# .maf/coordination/workers.json maps each worker id to its role, harness, model,
# start mode, and worktree. `maf prepare` and `maf start` write it.
# `maf retire` removes an entry. The dashboard reads it.
require "json"
require "fileutils"
require "time"
require_relative "shared/processes"

module Maf
  class Workers
    def self.at(root) = new(File.join(root, ".maf", "coordination", "workers.json"))

    # "backend-developer_2" (the maf start form) and "backend-developer-2"
    # (the worker id) name the same worker.
    def self.id(spec) = spec.include?("_") ? spec.sub(/_(?=[^_]*\z)/, "-") : spec

    def initialize(path)
      @path = path
    end

    def all = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    def find(worker) = all[worker]
    def add(worker, entry) = write(all.merge(worker => entry.merge("updated_at" => Time.now.utc.iso8601)))
    def remove(worker) = write(all.except(worker))
    def update(worker, fields) = add(worker, find(worker).to_h.merge(fields))

    def dispatcher?(worker)
      pid = find(worker)&.fetch("pid", nil)
      pid ? Shared::Processes.same?(pid, started(worker)) : false
    end

    def started(worker)
      entry = find(worker).to_h
      presence = presence(worker)
      recorded = entry["started"].to_s
      recorded.empty? && presence["pid"].to_i == entry["pid"].to_i ? presence["started"] : entry["started"]
    end

    def running?(worker)
      return dispatcher?(worker) unless started(worker).to_s.empty?

      presence(worker)["pid"].to_i == find(worker).to_h["pid"].to_i && Shared::Processes.live?(presence(worker))
    end

    def presence(worker) = read(File.join(File.dirname(@path), "presence", "#{worker}.json"))

    private

    def read(path)
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end

    def write(data)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(data))
    end
  end
end
