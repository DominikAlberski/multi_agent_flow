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

    # Only the installed harnesses are choices. Each role gets its own model.
    def add
      harness = @prompt.choose("Harness", Flow::Models.installed) or return
      roles = @prompt.choose_many("Roles", Maf.role_names)
      return if roles.empty?

      models = show_models(harness)
      Maf.flow(*roles.flat_map { |role| ["--agent", agent_spec(harness, role, models)] })
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

    def agent_spec(harness, role, models)
      model = ask_model(harness, role, models).to_s
      [harness, role, model].reject(&:empty?).join(":")
    end

    # The answer is a number of the list, a model name, or Enter for the default.
    # A name that the harness does not list needs a confirmation: a typo makes
    # every dispatched run fail.
    def ask_model(harness, role, models)
      answer = @prompt.ask("Model for #{role} (number or name, Enter = #{default_label(harness)}):").to_s
      number = Integer(answer, exception: false)
      return models[number - 1] if number&.between?(1, models.size)
      return answer if answer.empty? || Flow::Models.known?(harness, answer)

      @prompt.confirm?("#{harness} does not list #{answer}. Use it anyway?") ? answer : ask_model(harness, role, models)
    end

    def default_label(harness) = Flow::DEFAULT_MODELS.fetch(harness, "the harness default")

    def show_models(harness)
      models = Flow::Models.for(harness).to_a
      @prompt.say(models.empty? ? "#{harness} lists no models. Type a name." : "Models of #{harness}:")
      models.each_with_index { |model, i| @prompt.say("  #{i + 1}) #{model}") }
      models
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
