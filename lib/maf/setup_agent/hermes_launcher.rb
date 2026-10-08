# frozen_string_literal: true

module Maf
  module SetupAgent
    module Launcher
      # Hermes loads role files as skills from <hermes_dir>/<project>-<role>/.
      # flow.rb writes the skill there; --skills <project>-<role> loads it.
      # Hermes has no --agent flag; the skill's SKILL.md is the role definition.
      # `-q` on a TTY seeds an interactive session with the prompt.
      # A lead role owns no task, so it gets an inbox prompt. A role with
      # can_edit false starts without the file-writing toolsets.
      module Hermes
        PROMPT = "Follow the coordination rules of your role skill as role %<role>s. " \
                 "Run coord inbox, then coord next --wait. Claim a task, do the work, finish it. Repeat."
        LEAD_PROMPT = "Follow your role skill and its coordination rules as role %<role>s. " \
                      "You are a lead role. Never claim a task. Run coord inbox --wait and handle each message."

        def self.launch(role, _worker, model)
          cmd = %w[hermes chat]
          cmd += ["--skills", HermesSkill.name(role)] if HermesSkill.installed?(role)
          cmd += ["--model", model] if model
          cmd += ["-t", Flow::READ_ONLY_TOOLSETS] if read_only?(role)
          Launcher.exec_or_die(cmd + ["-q", prompt(role)])
        end

        def self.prompt(role) = format(Flow::LEADS.include?(role) ? LEAD_PROMPT : PROMPT, role: role)

        def self.read_only?(role)
          Project.manifest.fetch("agents", []).any? { |agent| agent["role"] == role && agent["can_edit"] == false }
        end
      end
    end
  end
end
