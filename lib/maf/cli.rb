# frozen_string_literal: true

# Maf::CLI maps maf subcommands to the installer code. The project is always
# the current directory.
require "json"
require "yaml"
require_relative "flow"
require_relative "uninstall"
require_relative "migrate"
require_relative "setup_agent"
require_relative "menu"
require_relative "team"
require_relative "team_command"
require_relative "worker_control"
require_relative "untrack"

module Maf
  MANIFEST = ".maf/config.json"

  def self.flow(*args) = Flow::Generator.new(["--project", Dir.pwd, *args]).run
  def self.role_names = Flow::RoleCatalog.new(Dir.pwd).roles.keys

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
      "roles" => "                                        list the built-in roles and the project roles",
      "role" => "add NAME                                add a stub role to .maf/roles.yml",
      "start" => "[HARNESS ROLE[_WORKER]] [--dispatch [--detach]]  start one agent in its worktree",
      "prepare" => "HARNESS ROLE[_WORKER] [--dispatch|--interactive] [--replace W]  prepare a worker; " \
                   "--dispatch starts it (default for the architect)",
      "retire" => "ROLE[_WORKER]                           remove a worker; its tasks return to the pool",
      "worker" => "status|stop|start|restart ROLE[_WORKER] [--force] [--max-context N] [--max-session-runs N] " \
                  "[--cache-window S]  control one worker; start and restart save the session limits of the role",
      "team" => "[set --max N --allow HARNESS[:MODEL]]   show the team, or set its budget",
      "uninstall" => "[--check] [--yes] [--force]             remove the flow from the project",
      "migrate" => "[--check] [--yes]                       move an old-layout install into .maf/",
      "untrack" => "[--check] [--yes]                       remove the flow from git; the files stay (then commit)",
      "menu" => "                                        interactive mode (also: maf without a command)"
    }.freeze

    def initialize(argv)
      @command, *@args = argv
    end

    def run
      return run_menu if @command.nil? && $stdin.tty?
      return help if @command.nil? || %w[help -h --help].include?(@command)
      abort "maf: unknown command '#{@command}'. Run: maf help" unless COMMANDS.key?(@command)
      abort "maf: #{Migrate::HINT}" if old_layout?

      send("run_#{@command}")
    end

    private

    # Every command except these needs the new layout.
    # maf uninstall --check previews the migration on an old layout.
    def old_layout?
      return false if %w[migrate roles menu].include?(@command) || uninstall_check?

      Migrate.old_layout?(Dir.pwd)
    end

    def uninstall_check? = @command == "uninstall" && @args.include?("--check")

    def help
      puts "Usage: maf COMMAND [ARGS]   (run in the project root)", ""
      COMMANDS.each { |name, text| puts "  maf #{name.ljust(10)}#{text}" }
    end

    def run_add = Maf.flow(*AgentArgs.convert(@args, "--agent"))
    def run_remove = Maf.flow(*AgentArgs.convert(@args, "--remove"))
    def run_update = Maf.flow(*@args)
    def run_roles = Maf.flow("--list-roles")

    def run_role
      abort "usage: maf role add NAME" unless @args.first == "add" && @args[1]

      added = Flow::RoleStub.new(Dir.pwd, @args[1]).add == :create
      puts(added ? "Role added: #{Flow::RoleCatalog::FILE}. Fill in the TODO lines." : "Role exists: #{@args[1]}")
    end
    def run_start = @args.empty? ? SetupAgent.run_here : SetupAgent.run(@args)
    def run_prepare = Prepare.new(@args).run
    def run_team = TeamCommand.new(@args, SetupAgent::Project.root).run
    def run_worker
      spec = @args[1] || abort(worker_usage)
      limits = RoleLimits.parse(@args)
      WorkerControl.new(SetupAgent::Project.root, spec, force: @args.include?("--force"), limits: limits)
        .run(@args[0].to_s)
    end

    def worker_usage = "usage: maf worker #{WorkerControl::ACTIONS.join("|")} ROLE[_WORKER] [--force] " \
                       "[--max-context N] [--max-session-runs N] [--cache-window S]"
    def run_retire = Retire.new(SetupAgent::Project.root, @args.first || abort("usage: maf retire ROLE[_WORKER]")).run
    def run_uninstall = Uninstall::Runner.new(["--project", Dir.pwd, *@args]).run
    def run_menu = Menu.new.run
    def run_untrack = Untrack.new(SetupAgent::Project.root, @args).run
    def run_migrate = Migrate::Runner.new(["--project", Dir.pwd, *@args]).run

    def run_agents
      return puts("No agents yet. Add one: maf add HARNESS:ROLE") if Maf.agents.empty?

      Maf.agents.each { |a| puts agent_line(a) }
    end

    def agent_line(agent)
      "#{agent["harness"]}:#{agent["role"]}".ljust(32) + agent["model"].to_s
    end
  end
end
