# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "../harness/traits"
require_relative "../roles"

module Maf
  module Shared
    module Harnesses
      # Hermes loads role files as skills from <hermes_dir>/<project>-<role>/,
      # outside the project. `--skills <project>-<role>` loads one. Hermes has
      # no agent flag and cannot be woken, so an idle agent blocks in
      # `coord next --wait`. A role with can_edit false starts without the
      # file-writing toolsets. Hermes keeps hooks and MCP servers in global
      # files, so maf prints the commands that add them.
      class Hermes < Harness::Base
        include Harness::ResultEvent

        DEFAULT_DIR = File.join(Dir.home, ".hermes", "skills")
        MAX_TURNS = 50
        # Stop Hermes before the dispatcher kills it, so it can still write its
        # result event. NOTE: assets/dispatcher Spawn::GRACE.
        KILL_GRACE = 5

        def role_destination(project, role, settings = {})
          File.join(settings["hermes_dir"] || DEFAULT_DIR, "#{File.basename(project)}-#{role}", "SKILL.md")
        end

        def role_template = <<~ERB
          ---
          # >>> multi-agent-flow >>>
          name: <%= role %>
          description: <%= description %>
          ---

          # <%= title %>

          <% if model -%>
          > Model: `<%= model %>` (Hermes sets the model with `hermes model`)
          <% end -%>
          <%= prompt %>
        ERB

        def model_hint(_model) = "hermes model"
        def mcp_command(server, vault) = "hermes mcp add #{server} --command ruby --args #{vault} mcp"
        def install_hooks(_project) = Flow::HermesHookSetup.new.install
        def global_files = [File.join(Dir.home, ".hermes", "agent-hooks", "next-task.sh")]

        # The skill name uses the main checkout's name, from the project root
        # and from a worktree alike.
        def skill_name(role) = "#{File.basename(Project.root)}-#{role}"

        # The skill that maf add generated for the role, or nil.
        def skill(role)
          dir = Project.manifest.fetch("hermes_dir", DEFAULT_DIR)
          File.exist?(File.join(dir, skill_name(role), "SKILL.md")) ? skill_name(role) : nil
        end

        def read_only?(role)
          Project.manifest.fetch("agents", []).any? { |agent| agent["role"] == role && agent["can_edit"] == false }
        end

        def tools(role) = read_only?(role) ? ["-t", Roles::READ_ONLY_TOOLSETS] : []

        PROMPT = "Follow the coordination rules of your role skill as role %<role>s. " \
                 "Run coord inbox, then coord next --wait. Claim a task, do the work, finish it. Repeat."
        LEAD_PROMPT = "Follow your role skill and its coordination rules as role %<role>s. " \
                      "You are a lead role. Never claim a task. Run coord inbox --wait and handle each message."

        # `-q` on a TTY seeds an interactive session with the prompt.
        def launch(role, model)
          prompt = format(Roles::LEADS.include?(role) ? LEAD_PROMPT : PROMPT, role: role)
          ["hermes", "chat", *skill(role)&.then { |name| ["--skills", name] }, *model_flag(model), *tools(role),
           "-q", prompt]
        end

        # --no-skill drops the skill. Without --skill, the generated skill of the role loads.
        def prepare(config)
          config.skill = nil if config.no_skill
          config.skill ||= skill(config.role) unless config.no_skill
          config.max_turns ||= MAX_TURNS
          config
        end

        # `hermes chat --oneshot` with JSONL output and the skill preloaded.
        def build_command(config, prompt, session_id)
          cmd = %w[hermes chat --oneshot --yolo --format stream-json -Q]
          cmd += [*(["--skills", config.skill] if config.skill), *model_flag(config.model), *tools(config.role)]
          cmd += ["--max-turns", config.max_turns.to_s, "--run-budget", [config.timeout - KILL_GRACE, 1].max.to_s]
          cmd + resume(session_id, "--resume") + ["-q", prompt]
        end

        def stale_session?(output) = output.include?("Session not found")
        def result_text(output) = result_event(output)["text"]
      end
    end
  end
end
