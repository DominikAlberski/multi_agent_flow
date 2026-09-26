# frozen_string_literal: true

# workers.rb - registry of the workers that run in this project.
#
# coordination/workers.json maps each worker id to its role, harness, model,
# start mode, and worktree. `maf prepare` and `maf start` write it.
# `maf retire` removes an entry. The dashboard reads it.
require "json"
require "fileutils"
require "time"

module Maf
  class Workers
    def self.at(root) = new(File.join(root, "coordination", "workers.json"))

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

    private

    def write(data)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(data))
    end
  end
end
