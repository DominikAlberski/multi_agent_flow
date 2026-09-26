# frozen_string_literal: true

# Maf::CLI maps maf subcommands to the installer code. The project is always
# the current directory.
require "json"
require "yaml"
require_relative "flow"
require_relative "uninstall"
require_relative "setup_agent"
require_relative "menu"
require_relative "team"

module Maf
  MANIFEST = ".agent-flow.json"

  def self.flow(*args) = Flow::Generator.new(["--project", Dir.pwd, *args]).run
  def self.role_names = YAML.load_file(File.join(Flow::TEMPLATES, "roles.yml")).fetch("roles").keys

  def self.agents = File.exist?(MANIFEST) ? JSON.parse(File.read(MANIFEST)).fetch("agents") : []
  def self.agent_specs = agents.map { |a| "#{a["harness"]}:#{a["role"]}" }

  # AgentArgs turns the bare HARNESS:ROLE arguments of add and remove into
  # flow.rb flags. Flag values (for example --model ROLE=MODEL) stay as they are.
  module AgentArgs
    def self.convert(args, flag)
      args.each_with_index.flat_map { |arg, i| spec?(arg, i.zero? ? nil : args[i - 1]) ? [flag, arg] : [arg] }
    end

    def self.spec?(arg, before) = !arg.start_with?("-") && !value_flags.include?(before)
    def self.value_flags = @value_flags ||= Flow::Generator.value_flags
  end

  class CLI
    COMMANDS = {
      "add" => "HARNESS:ROLE ... [--model ROLE=MODEL]  add agents and install the flow",
      "remove" => "HARNESS:ROLE ...                        remove agents",
      "update" => "                                        regenerate the files of the current agents",
      "agents" => "                                        list the current agents",
      "roles" => "                                        list the available roles",
      "start" => "[HARNESS ROLE[_WORKER]] [--dispatch]    start one agent in its worktree",
      "prepare" => "HARNESS ROLE[_WORKER] [--replace W]    prepare a worker; the user then runs maf start",
      "retire" => "ROLE[_WORKER]                           remove a worker; its tasks return to the pool",
      "uninstall" => "[--check] [--yes] [--force]             remove the flow from the project",
      "menu" => "                                        interactive mode (also: maf without a command)"
    }.freeze

    def initialize(argv)
      @command, *@args = argv
    end

    def run
      return run_menu if @command.nil? && $stdin.tty?
      return help if @command.nil? || %w[help -h --help].include?(@command)
      abort "maf: unknown command '#{@command}'. Run: maf help" unless COMMANDS.key?(@command)

      send("run_#{@command}")
    end

    private

    def help
      puts "Usage: maf COMMAND [ARGS]   (run in the project root)", ""
      COMMANDS.each { |name, text| puts "  maf #{name.ljust(10)}#{text}" }
    end

    def run_add = Maf.flow(*AgentArgs.convert(@args, "--agent"))
    def run_remove = Maf.flow(*AgentArgs.convert(@args, "--remove"))
    def run_update = Maf.flow(*@args)
    def run_roles = Maf.flow("--list-roles")
    def run_start = @args.empty? ? SetupAgent.run_here : SetupAgent.run(@args)
    def run_prepare = Prepare.new(@args).run
    def run_retire = Retire.new(SetupAgent::Project.root, @args.first || abort("usage: maf retire ROLE[_WORKER]")).run
    def run_uninstall = Uninstall::Runner.new(["--project", Dir.pwd, *@args]).run
    def run_menu = Menu.new.run

    def run_agents
      return puts("No agents yet. Add one: maf add HARNESS:ROLE") if Maf.agents.empty?

      Maf.agents.each { |a| puts agent_line(a) }
    end

    def agent_line(agent)
      "#{agent["harness"]}:#{agent["role"]}".ljust(32) + agent["model"].to_s
    end
  end
end
