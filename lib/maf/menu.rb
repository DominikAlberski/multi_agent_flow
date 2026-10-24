# frozen_string_literal: true

require_relative "prompt"
require_relative "sandbox_choice"

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

    # Only the installed harnesses are choices. Each role gets its own model and effort.
    def add
      harness = @prompt.choose("Harness", Flow::Models.installed) or return
      roles = @prompt.choose_many("Roles", Maf.role_names)
      return if roles.empty?

      models = show_models(harness)
      Maf.flow(*roles.flat_map { |role| agent_args(harness, role, models) }, *SandboxChoice.new(@prompt).args)
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

    def agent_args(harness, role, models)
      model = ask_model(harness, role, models).to_s
      effort = ask_effort(harness, role, model.empty? ? nil : model).to_s
      flags = effort.empty? ? [] : ["--effort", "#{role}=#{effort}"]
      ["--agent", [harness, role, model].reject(&:empty?).join(":"), *flags]
    end

    # A model name that the harness does not list needs a confirmation: a typo
    # makes every dispatched run fail.
    def ask_model(harness, role, models)
      question = "Model for #{role} (number or name, Enter = #{default_label(harness)}):"
      ask_listed(harness, question, models) { |name| Flow::Models.known?(harness, name) }
    end

    def default_label(harness) = Flow::Models.default(harness) || "the harness default"

    def show_models(harness)
      models = Flow::Models.for(harness).to_a
      @prompt.say(models.empty? ? "#{harness} lists no models. Type a name." : "Models of #{harness}:")
      models.each_with_index { |model, i| @prompt.say("  #{i + 1}) #{model}#{levels_label(harness, model)}") }
      models
    end

    def levels_label(harness, model)
      levels = Flow::Models.efforts(harness, model).to_a
      levels.empty? ? "" : "  (effort: #{levels.join(", ")})"
    end

    # An empty list: the model takes no level, so maf does not ask.
    # nil: the harness lists no levels, so every level counts as known.
    def ask_effort(harness, role, model)
      levels = Flow::Models.efforts(harness, model)
      return if levels == []

      levels.to_a.each_with_index { |level, i| @prompt.say("  #{i + 1}) #{level}") }
      question = "Effort for #{role} (number or name, Enter = #{effort_label(harness, role, model)}):"
      ask_listed(harness, question, levels.to_a) { |name| levels.nil? || levels.include?(name) }
    end

    def effort_label(harness, role, model)
      Flow::Models.default_effort(harness, Maf.role_effort(role), model) || "the harness default"
    end

    # The answer is a number of the list, a name, or Enter for the default.
    def ask_listed(harness, question, list, &known)
      answer = @prompt.ask(question).to_s
      picked = pick(answer, list, &known)
      return picked if picked
      return answer if @prompt.confirm?("#{harness} does not list #{answer}. Use it anyway?")

      ask_listed(harness, question, list, &known)
    end

    def pick(answer, list)
      number = Integer(answer, exception: false)
      return list[number - 1] if number&.between?(1, list.size)

      answer if answer.empty? || yield(answer)
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
