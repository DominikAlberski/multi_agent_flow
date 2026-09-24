# frozen_string_literal: true

# Maf::CLI maps maf subcommands to the installer code. The project is always
# the current directory.
require "json"
require_relative "flow"
require_relative "uninstall"
require_relative "setup_agent"

module Maf
  # AgentArgs turns the bare HARNESS:ROLE arguments of add and remove into
  # flow.rb flags. Flag values (for example --model ROLE=MODEL) stay as they are.
  module AgentArgs
    VALUE_FLAGS = %w[--model --hermes-dir].freeze

    def self.convert(args, flag)
      args.each_with_index.flat_map { |arg, i| spec?(arg, i.zero? ? nil : args[i - 1]) ? [flag, arg] : [arg] }
    end

    def self.spec?(arg, before) = !arg.start_with?("-") && !VALUE_FLAGS.include?(before)
  end

  class CLI
    MANIFEST = ".agent-flow.json"
    COMMANDS = {
      "add" => "HARNESS:ROLE ... [--model ROLE=MODEL]  add agents and install the flow",
      "remove" => "HARNESS:ROLE ...                        remove agents",
      "update" => "                                        regenerate the files of the current agents",
      "agents" => "                                        list the current agents",
      "roles" => "                                        list the available roles",
      "start" => "HARNESS ROLE[_WORKER] [--dispatch]      start one agent in its worktree",
      "uninstall" => "[--check] [--yes] [--force]             remove the flow from the project"
    }.freeze

    def initialize(argv)
      @command, *@args = argv
    end

    def run
      return help if @command.nil? || %w[help -h --help].include?(@command)
      abort "maf: unknown command '#{@command}'. Run: maf help" unless COMMANDS.key?(@command)

      send("run_#{@command}")
    end

    private

    def help
      puts "Usage: maf COMMAND [ARGS]   (run in the project root)", ""
      COMMANDS.each { |name, text| puts "  maf #{name.ljust(10)}#{text}" }
    end

    def run_add = flow(*AgentArgs.convert(@args, "--agent"))
    def run_remove = flow(*AgentArgs.convert(@args, "--remove"))
    def run_update = flow(*@args)
    def run_roles = flow("--list-roles")
    def run_start = SetupAgent.run(@args)
    def run_uninstall = Uninstall::Runner.new(["--project", Dir.pwd, *@args]).run

    def run_agents
      return puts("No agents yet. Add one: maf add HARNESS:ROLE") unless File.exist?(MANIFEST)

      JSON.parse(File.read(MANIFEST)).fetch("agents").each { |a| puts agent_line(a) }
    end

    def agent_line(agent)
      "#{agent["harness"]}:#{agent["role"]}".ljust(32) + agent["model"].to_s
    end

    def flow(*args)
      Flow::Generator.new(["--project", Dir.pwd, *args]).run
    end
  end
end
