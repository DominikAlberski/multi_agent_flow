# frozen_string_literal: true

module Flow
  # PromptBuilder builds the prompt text of one role file.
  class PromptBuilder
    def initialize(roles, agents, workflow = nil)
      @roles = roles
      @agents = agents
      @workflow = workflow
    end

    def build(harness, role, data) = "#{role_prompt(harness, role, data).rstrip}\n\n#{CONTRACT}\n"

    private

    def role_prompt(harness, role, data)
      return project_manager_prompt(harness, data) if role == "project-manager"
      return architect_prompt(harness, data) if role == "architect"

      worker_prompt(harness, role, data)
    end

    def worker_prompt(harness, role, data)
      loop_text = format(WORKER_LOOP, role: role, no_task_instruction: no_task_line(harness))
      "#{intro(data)}\n\n#{duties_block(data)}\n\n#{loop_text}"
    end

    # Claude Code wakes an idle session with the board-watch hook, and opencode
    # with the board-watch plugin. So these agents stop instead of waiting:
    # each return of a wait costs one model call over the whole context.
    # Codex waits in its stop hook after `coord await`. Hermes cannot be
    # woken, so it blocks in `coord next --wait`.
    # The dispatcher adds the report block rule to each dispatched prompt.
    def no_task_line(harness)
      return NO_TASK_AWAIT if harness == "codex"

      WAKE_HARNESSES.include?(harness) ? NO_TASK_STOP : NO_TASK_WAIT
    end

    def architect_prompt(harness, data)
      loop_text = project_manager? ? ARCHITECT_LOOP_PM : ARCHITECT_LOOP_DIRECT
      "#{intro(data)} You do not implement code yourself.\n\n#{duties_block(data)}\n\n" \
        "#{format(loop_text, roles: dispatch_roles_text)}#{claude_rule(harness)}#{workflow_block}"
    end

    # The loop text ends with a newline, so the rule lands as the last rule line.
    def claude_rule(harness) = harness == "claude" ? "#{CLAUDE_ARCHITECT_RULE}\n" : ""

    # The workflow goes into the orchestrator prompt only. Workers stay workflow-blind.
    def workflow_block = @workflow ? "\n\n#{@workflow}" : ""

    def project_manager?
      @agents.any? { |a| a[:role] == "project-manager" }
    end

    def project_manager_prompt(harness, data)
      "#{intro(data)} You do not plan tasks or implement code yourself.\n\n" \
        "#{duties_block(data)}\n\n#{format(PM_LOOP, wait_instruction: PM_WAIT.fetch(harness, PM_WAIT_DEFAULT))}"
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
