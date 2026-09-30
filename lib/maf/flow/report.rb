# frozen_string_literal: true

module Flow
  # Report prints the result of a run and the next steps for the user.
  class Report
    def initialize(project, roles, hermes_pending)
      @project = project
      @roles = roles
      @hermes_pending = hermes_pending
    end

    def print(results)
      puts
      puts "Generated role files:"
      results.each { |result| puts generated_line(result) }
      print_missing_models(results)
      print_unembeddable(results)
      print_sessions(results)
      print_hermes_reminder
    end

    private

    # The hook steps print at install time, far above the last lines the user
    # reads. Repeat the state here so the flow is not started with a dead hook.
    def print_hermes_reminder
      return unless @hermes_pending

      puts "The Hermes hook is not active yet. Finish the steps above."
      puts "Then run `maf update` to confirm the hook is ready."
    end

    def generated_line(result)
      "  #{result[:status].to_s.ljust(7)} #{result[:agent][:harness]}:" \
        "#{result[:agent][:role]} -> #{result[:dest]}"
    end

    def print_missing_models(results)
      missing = results.reject { |result| result[:model] }
      return if missing.empty?

      puts
      puts "No model chosen for these roles. maf leaves the choice to you. Suggestions:"
      missing.each { |result| puts "  #{result[:agent][:role]}: #{model_hint(result)}" }
      puts "  Set one with: --model <role>=<provider/model>"
    end

    def model_hint(result)
      @roles.fetch(result[:agent][:role]).fetch("model_hint")
    end

    def print_sessions(results)
      puts
      puts "Next: start one session per agent in #{@project}:"
      results.each { |result| puts "  maf start #{result[:agent][:harness]} #{result[:agent][:role]}" }
      puts
      puts "In each worker session, paste:"
      puts %(  "Run ./coord inbox <role>. Then work the pending tasks assigned to you. Repeat.")
      puts entry_point_hint(results)
    end

    def entry_point_hint(results)
      roles = results.map { |result| result[:agent][:role] }
      return "Talk to the project manager session. It hands goals to the architect." if roles.include?("project-manager")

      "In the architect session, describe what you want built."
    end

    def print_unembeddable(results)
      list = results.select { |r| r[:model] && %w[codex hermes].include?(r[:agent][:harness]) }
      return if list.empty?

      puts
      puts "These harnesses cannot embed a model in the role file. Set it in the harness:"
      list.each { |r| puts "  #{r[:agent][:harness]}:#{r[:agent][:role]} -> #{model_command(r)}" }
    end

    def model_command(result)
      result[:agent][:harness] == "codex" ? "codex -m #{result[:model]}" : "hermes model"
    end
  end
end
