# frozen_string_literal: true

module Maf
  module Flow
    # Report prints the result of a run and the next steps for the user.
    class Report
      def initialize(project, roles, hermes_pending)
        @project = project
        @roles = roles
        @hermes_pending = hermes_pending
      end

      def print(results)
        puts "", "Generated role files:", results.map { |result| generated_line(result) }
        %i[print_missing_models print_unknown_models print_unembeddable print_sessions]
          .each { |name| send(name, results) }
        print_hermes_reminder
      end

      private

      # The hook steps print at install time, far above the last lines the user
      # reads. Repeat the state here so the flow is not started with a dead hook.
      def print_hermes_reminder
        return unless @hermes_pending

        puts "The Hermes hook is not active yet. Finish the steps above.",
             "Then run `maf update` to confirm the hook is ready."
      end

      def generated_line(result)
        "  #{result[:status].to_s.ljust(7)} #{result[:agent][:harness]}:" \
          "#{result[:agent][:role]} -> #{result[:dest]}"
      end

      def print_missing_models(results)
        missing = results.reject { |result| result[:model] }.map { |result| "  #{model_hint(result)}" }
        return if missing.empty?

        puts "", "No model chosen for these roles. maf leaves the choice to you. Suggestions:", missing,
             "  Set one with: --model <role>=<provider/model>"
      end

      # A dispatched run with an unknown model fails before it reaches the model.
      def print_unknown_models(results)
        unknown = results.select { |r| r[:model] && !Models.known?(r[:agent][:harness], r[:model]) }
        return if unknown.empty?

        puts "", "WARNING: the harness does not list these models. Check the name for a typo:",
             unknown.map { |r| "  #{r[:agent][:harness]}:#{r[:agent][:role]} -> #{r[:model]}" },
             "  Fix one with: maf add HARNESS:ROLE:MODEL"
      end

      def model_hint(result)
        role = result[:agent][:role]
        "#{role}: #{@roles.fetch(role).fetch("model_hint")}"
      end

      PASTE_HINT = %(  "Run coord inbox <role>. Then work the pending tasks assigned to you. Repeat.")

      def print_sessions(results)
        puts "", "Next: start one session per agent in #{@project}:",
             results.map { |result| "  maf start #{result[:agent][:harness]} #{result[:agent][:role]}" },
             "", "In each worker session, paste:",
             PASTE_HINT, entry_point_hint(results)
      end

      def entry_point_hint(results)
        return "In the architect session, describe what you want built." if results.none? { |r| pm?(r) }

        "Talk to the project manager session. It hands goals to the architect."
      end

      def pm?(result) = result[:agent][:role] == "project-manager"

      def print_unembeddable(results)
        list = results.select { |r| r[:model] && %w[codex hermes].include?(r[:agent][:harness]) }
        return if list.empty?

        puts "", "These harnesses cannot embed a model in the role file. Set it in the harness:",
             list.map { |r| "  #{r[:agent][:harness]}:#{r[:agent][:role]} -> #{model_command(r)}" }
      end

      def model_command(result)
        result[:agent][:harness] == "codex" ? "codex -m #{result[:model]}" : "hermes model"
      end
    end
  end
end
