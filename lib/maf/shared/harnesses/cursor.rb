# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "open3"
require_relative "../harness/traits"

module Maf
  module Shared
    module Harnesses
      # The Cursor CLI (`agent`). The role files in .cursor/agents/ are Cursor
      # subagents. The CLI has no flag that picks one, so maf start names the
      # role file in the prompt, and the dispatcher puts the role text in front
      # of the first prompt. Cursor reads MCP servers only from .cursor/mcp.json,
      # so the flow passes no MCP config. Cursor has no wake-up hook yet.
      class Cursor < Harness::Base
        include Harness::ResultEvent
        include Harness::PrependsRole

        def command = "agent"
        def role_dir = ".cursor/agents"
        def sandbox_dirs = [File.join(Dir.home, ".cursor"), File.join(Dir.home, ".config", "cursor")]
        PROTECTED = %w[cli-config.json hooks.json mcp.json hooks agents skills plugins rules].freeze
        def sandbox_protected = in_dir(File.join(Dir.home, ".cursor"), PROTECTED)
        def sandbox_placeholders = super - [File.join(Dir.home, ".cursor", "cli-config.json")]
        STATE = %w[.cursor/agent-cli-state.json* .cursor/statsig-cache.json* .cursor/chats .cursor/projects
                   .cursor/ai-tracking .config/cursor/auth.json* .config/cursor/*.lock].freeze
        def sandbox_state = in_dir(Dir.home, STATE)
        PROJECT = %w[.cursor/mcp.json .cursor/hooks.json .cursor/hooks .cursor/cli.json .cursor/agents].freeze
        def sandbox_project = PROJECT
        def vm_install = "curl -fsSL https://cursor.com/install | bash"
        def vm_login_hint = "maf vm shell, then NO_OPEN_BROWSER=1 agent login (or export CURSOR_API_KEY)"

        def role_template = <<~ERB
          ---
          # >>> multi-agent-flow >>>
          name: <%= role %>
          description: <%= description %>
          <% if model -%>
          model: <%= model %>
          <% end -%>
          readonly: <%= !can_edit %>
          ---

          <%= prompt %>
        ERB

        def launch(role, model, effort = nil)
          ["agent", *model_flag(CursorModels.name(model, effort)),
           "Read #{role_path(role)} and follow it exactly. Start your work loop now."]
        end

        # `agent -p --output-format json` prints one result object with session_id and result.
        def build_command(config, prompt, session_id)
          %w[agent -p --output-format json --force --trust
             --approve-mcps] + model_flag(CursorModels.name(config.model, config.effort)) +
            resume(session_id, "--resume") + [first_prompt(config.role, prompt, session_id)]
        end

        # Cursor has no effort flag. The level is a part of the model name, so
        # maf lists each model without its level, and the levels of each model.
        def models = CursorModels.bases

        def known_model?(model, list = models)
          list.nil? || list.include?(model) || CursorModels.listed.include?(model)
        end

        def efforts(model = nil) = CursorModels.efforts(model)
        def effort_required?(model) = CursorModels.effort_required?(model)

        # A failed run prints no JSON, only an error on stderr. So a resume
        # without a result event and with "not found" is stale. Cursor reports no token usage.
        def stale_session?(output) = result_event(output).empty? && output.match?(/not found/i)
      end

      # CursorModels reads `agent --list-models`. A name is BASE-LEVEL or
      # BASE-LEVEL-fast, for example gpt-5.3-codex-high-fast.
      module CursorModels
        LEVELS = %w[low medium high xhigh max].freeze
        LEVEL = /-(#{LEVELS.join("|")})(?=(?:-fast)?\z)/

        def self.listed
          return @listed if defined?(@listed)

          @listed = read
        end

        def self.read
          out, status = Open3.capture2("agent", "--list-models", err: File::NULL)
          status.success? ? out.scan(/^(\S+) - /).flatten : nil
        rescue SystemCallError
          nil
        end

        def self.bases = listed&.map { |model| model.sub(LEVEL, "") }&.uniq

        # nil: maf cannot read the list.
        def self.efforts(model)
          return nil unless listed
          return [] unless model

          LEVELS.select { |level| listed.include?(name(model, level)) }
        end

        # A base that Cursor does not list by itself runs only with a level.
        def self.effort_required?(model) = !listed.nil? && !listed.include?(model) && !efforts(model).to_a.empty?

        def self.name(model, effort)
          return model unless model && effort

          model.end_with?("-fast") ? model.sub(/-fast\z/, "-#{effort}-fast") : "#{model}-#{effort}"
        end
      end
    end
  end
end
