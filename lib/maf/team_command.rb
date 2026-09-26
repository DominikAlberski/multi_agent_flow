# frozen_string_literal: true

# team_command.rb - show the team, or set its limits.
#
#   maf team
#   maf team set --max N [--allow HARNESS[:MODEL] ...]
require "json"
require "optparse"
require_relative "workers"
require_relative "budget"
require_relative "retire"
require_relative "team"

module Maf
  class TeamCommand
    def initialize(argv, root)
      @argv = argv
      @root = root
    end

    def run = @argv.first == "set" ? set(@argv.drop(1)) : show

    private

    def show
      puts Budget.at(@root).summary, ""
      workers = Workers.at(@root).all
      puts "No workers yet. Add one: maf prepare HARNESS ROLE[_WORKER]" if workers.empty?
      workers.each { |id, entry| puts line(id, entry) }
      puts "", "Tasks by role:", Team.coord(@root, "status")
    end

    def line(id, entry)
      mode = entry["dispatch"] ? "dispatch" : "interactive"
      [id.ljust(28), entry["role"].to_s.ljust(20), entry["harness"], entry["model"] || "-", mode, state(entry)]
        .join("  ")
    end

    def state(entry)
      pid = entry["pid"]
      return "-" unless pid

      RunningProcesses.alive?(pid) ? "running (pid #{pid})" : "stopped"
    end

    # The team key is the user's budget. Keep every other manifest key.
    def set(args)
      team = parse(args)
      path = File.join(@root, ".agent-flow.json")
      File.write(path, JSON.pretty_generate(manifest(path).merge("team" => team)))
      puts Budget.new(team).summary
    end

    # A corrupt manifest must not be overwritten with only the team key: that
    # would drop every agent. Stop with a clear message instead.
    def manifest(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      abort "maf: #{path} is not valid JSON. Fix it, then run this command again."
    end

    def parse(args)
      team = { "allow" => [] }
      OptionParser.new do |o|
        o.on("--max N", Integer) { |v| team["max_workers"] = v }
        o.on("--allow SPEC") { |v| team["allow"] << v }
      end.parse!(args)
      team
    end
  end
end
