# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
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
        def vm_install = "curl -fsSL https://cursor.com/install | bash"

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

        def launch(role, model)
          ["agent", *model_flag(model), "Read #{role_path(role)} and follow it exactly. Start your work loop now."]
        end

        # `agent -p --output-format json` prints one result object with session_id and result.
        def build_command(config, prompt, session_id)
          %w[agent -p --output-format json --force --trust --approve-mcps] + model_flag(config.model) +
            resume(session_id, "--resume") + [first_prompt(config.role, prompt, session_id)]
        end

        # A failed run prints no JSON, only an error on stderr. So a resume
        # without a result event and with "not found" is stale. Cursor reports no token usage.
        def stale_session?(output) = result_event(output).empty? && output.match?(/not found/i)
      end
    end
  end
end
