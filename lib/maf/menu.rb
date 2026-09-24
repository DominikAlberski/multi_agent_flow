# frozen_string_literal: true

require_relative "prompt"

module Maf
  # Menu is the interactive mode of maf. It runs the same steps as the
  # subcommands, but asks for each value.
  class Menu
    ACTIONS = { "1" => ["Add agents", :add], "2" => ["Remove an agent", :remove],
                "3" => ["Start an agent", :start], "4" => ["List roles", :roles],
                "5" => ["Update the agent files", :update], "6" => ["Uninstall", :uninstall] }.freeze

    def initialize(prompt = Prompt.new)
      @prompt = prompt
    end

    def run
      loop do
        show_menu
        break unless handle(@prompt.ask("Choose:"))
      end
    end

    private

    def show_menu
      @prompt.say("\nmaf - #{Dir.pwd}")
      guarded { @prompt.say("Agents: #{Maf.agent_specs.join(", ").then { |s| s.empty? ? "none" : s }}") }
      ACTIONS.each { |key, (label, _)| @prompt.say("  #{key}) #{label}") }
      @prompt.say("  q) Quit")
    end

    def handle(answer)
      return false if answer.nil? || answer == "q"

      ACTIONS[answer] ? guarded { send(ACTIONS[answer].last) } : @prompt.say("invalid choice")
      true
    end

    # A failed step aborts or raises. The menu prints the error and keeps running.
    def guarded
      yield
    rescue SystemExit
      nil
    rescue StandardError => e
      @prompt.say("error: #{e.message}")
    end

    def add
      harness = @prompt.choose("Harness", Flow::HARNESSES) or return
      roles = @prompt.choose_many("Roles", Maf.role_names)
      Maf.flow(*roles.flat_map { |role| ["--agent", agent_spec(harness, role)] }) unless roles.empty?
    end

    def agent_spec(harness, role)
      model = @prompt.ask("Model for #{role} (Enter = default):").to_s
      [harness, role, model].reject(&:empty?).join(":")
    end

    def remove
      spec = @prompt.choose("Agent", Maf.agent_specs) or return
      Maf.flow("--remove", spec) if @prompt.confirm?("Remove #{spec}?")
    end

    def start
      harness, role = (@prompt.choose("Agent", Maf.agent_specs) or return).split(":")
      worker = @prompt.ask("Worker id (Enter = default):").to_s
      dispatch = @prompt.confirm?("Run unattended (--dispatch)?")
      SetupAgent.run([harness, worker.empty? ? role : "#{role}_#{worker}", *("--dispatch" if dispatch)])
    end

    def roles = Maf.flow("--list-roles")
    def update = Maf.flow
    def uninstall = Uninstall::Runner.new(["--project", Dir.pwd]).run
  end
end
