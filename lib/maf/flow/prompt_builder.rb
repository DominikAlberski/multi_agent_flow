# frozen_string_literal: true

module Flow
  # PromptBuilder builds the prompt text of one role file.
  class PromptBuilder
    def initialize(roles, agents)
      @roles = roles
      @agents = agents
    end

    def build(harness, role, data)
      case role
      when "project-manager" then project_manager_prompt(data)
      when "architect" then architect_prompt(data)
      else worker_prompt(harness, role, data)
      end
    end

    private

    def worker_prompt(harness, role, data)
      "#{intro(data)}\n\n#{duties_block(data)}\n\n#{format(WORKER_LOOP, role: role, no_task_instruction: no_task_line(harness))}"
    end

    # Claude Code wakes an idle session with the board-watch hook. Other
    # harnesses block in `coord next --wait`, which also returns on a message.
    # The opencode board-watch plugin wakes opencode if the wait loop stops.
    def no_task_line(harness)
      harness == "claude" ? NO_TASK_STOP : NO_TASK_WAIT
    end

    def architect_prompt(data)
      loop_text = project_manager? ? ARCHITECT_LOOP_PM : ARCHITECT_LOOP_DIRECT
      "#{intro(data)} You do not implement code yourself.\n\n#{duties_block(data)}\n\n" \
        "#{format(loop_text, roles: dispatch_roles_text)}"
    end

    def project_manager?
      @agents.any? { |a| a[:role] == "project-manager" }
    end

    def project_manager_prompt(data)
      "#{intro(data)} You do not plan tasks or implement code yourself.\n\n" \
        "#{duties_block(data)}\n\n#{PM_LOOP}"
    end

    def intro(data)
      "You are the #{data.fetch("title")} for this project."
    end

    def duties_block(data)
      lines = data.fetch("duties").strip.lines.map { |line| line.strip.empty? ? line : "  #{line}" }
      "Duties:\n#{lines.join}"
    end

    # What the architect can dispatch to: this run's worker roles, not every
    # role in roles.yml. Advertising a role nobody generated a session for
    # means tasks pile up unclaimed forever.
    def dispatch_roles
      @agents.map { |a| a[:role] }.uniq - DISPATCH_EXCLUDE
    end

    def dispatch_roles_text
      return "  (none requested yet in this run)" if dispatch_roles.empty?

      dispatch_roles.map { |r| "  - #{r}: #{@roles.fetch(r).fetch("description")}" }.join("\n")
    end
  end
end
