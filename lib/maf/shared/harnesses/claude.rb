# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "../harness/traits"

module Maf
  module Shared
    module Harnesses
      # Claude Code. `--agent` loads .claude/agents/<role>.md. The board-watch
      # hook wakes an idle session. Bootstrap installs the hooks into
      # .maf/claude/settings.json, and maf start passes the file with --settings.
      class Claude < Harness::Base
        include Harness::ResultEvent

        def role_dir = ".claude/agents"

        def role_template = <<~ERB
          ---
          # >>> multi-agent-flow >>>
          name: <%= role %>
          description: <%= description %>
          <% if model -%>
          model: <%= model %>
          <% end -%>
          <%# A tools list blocks each MCP tool that it does not name. -%>
          <% if can_edit -%>
          tools: Read, Write, Edit, Bash, Grep, Glob, mcp__graphify
          <% else -%>
          tools: Read, Bash, Grep, Glob, mcp__graphify
          <% end -%>
          ---

          <%= prompt %>
        ERB

        # Claude Code has no command that lists models. The aliases follow the
        # newest model of each family. A full ID is claude-<family>-<version>.
        MODELS = %w[claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-1 opus sonnet haiku fable].freeze
        MODEL_NAME = /\A(?:(?:opus|sonnet|haiku|fable)(?:\[1m\])?|opusplan|default|best|
                       (?:[\w.-]+\.)?(?:anthropic\.)?claude-(?:opus|sonnet|haiku|fable)-\d[\w.:@\[\]-]*)\z/x

        def models = MODELS
        def known_model?(model, _list = nil) = model.match?(MODEL_NAME)
        def default_model = "claude-opus-5-5"

        def wait = :watch
        def vm_install = "curl -fsSL https://claude.ai/install.sh | bash"
        LOGIN = ".claude/.credentials.json"
        def vm_credentials = [RUBY_PLATFORM.include?("darwin") ? keychain_login : file_login]
        def keychain_login = Harness::VmCredential.keychain("Claude Code-credentials", LOGIN)
        def file_login = Harness::VmCredential.file(File.join(sandbox_dirs.first, ".credentials.json"), LOGIN)

        def sandbox_dirs = [ENV.fetch("CLAUDE_CONFIG_DIR", File.join(Dir.home, ".claude"))]
        def sandbox_prefixes = [File.join(Dir.home, ".claude.json")]
        PROTECTED = %w[settings.json settings.local.json CLAUDE.md hooks skills agents commands plugins
                       output-styles rules].freeze
        def sandbox_protected = in_dir(sandbox_dirs.first, PROTECTED)
        STATE = %w[projects sessions session-env shell-snapshots file-history todos tasks plans paste-cache statsig
                   telemetry ide debug logs cache backups jobs downloads feedback state daemon daemon.log* daemon-auth-*
                   history.jsonl* stats-cache.json* *-cache.json* .last-* .credentials* .claude.json*].freeze
        LOGS = ["Library/Caches/claude-cli-nodejs", ".cache/claude-cli-nodejs"].freeze
        def sandbox_state = in_dir(sandbox_dirs.first, STATE) + in_dir(Dir.home, LOGS)
        PROJECT = %w[.mcp.json .claude/settings.json .claude/settings.local.json .claude/hooks .claude/commands
                     .claude/skills .claude/agents .claude/output-styles .claude/rules].freeze
        def sandbox_project = PROJECT

        # Only Claude Code has ScheduleWakeup.
        def architect_rule
          "- Never call ScheduleWakeup with `stop:false` and no `prompt`. " \
            "The call fails. Poll worker status through the task tool instead."
        end

        def mcp
          { file: ".maf/mcp/claude.json", key: "mcpServers",
            entry: { "command" => Harness::VAULT_MCP.first, "args" => Harness::VAULT_MCP.drop(1) } }
        end

        def legacy_mcp_file = ".mcp.json"
        # An older maf wrote the hooks into the project's .claude/settings.json.
        def legacy_cleaners(project) = [Uninstall::ClaudeSettings.new(project)]
        def bootstrap_dir = ".claude"

        # The hook commands run in the worktree. The settings file is in the main project.
        def runtime_hooks(_worktree)
          root = Project.root
          settings = File.join(root, Bootstrap::CLAUDE_SETTINGS)
          Bootstrap::ClaudeSettings.new(Bootstrap::Project.new(root, false)).configure(settings)
        end

        # --settings adds the hooks of the flow, --mcp-config adds the graph server.
        # --mcp-config takes many values, so `--` ends the options before the prompt.
        def launch(role, model)
          prompt = "Read #{role_path(role)} and follow it exactly. Start your work loop now."
          ["claude", *flag_if("--settings", flow_file("claude", "settings.json")),
           *flag_if("--mcp-config", flow_file("mcp", "claude.json")), *model_flag(model), "--", prompt]
        end

        # `claude -p` prints one JSON object with session_id and result.
        # LEAN starts no MCP server outside --mcp-config and lists no skill.
        # The user's CLAUDE.md and hooks stay.
        LEAN = %w[--strict-mcp-config --disable-slash-commands].freeze

        def build_command(config, prompt, session_id)
          cmd = %w[claude -p --output-format json --permission-mode bypassPermissions --agent] + [config.role]
          cmd += model_flag(config.model)
          cmd += LEAN if config.lean
          cmd + flag_if("--mcp-config", run_file(config, "mcp", "claude.json")) +
            resume(session_id, "--resume") + ["--", prompt]
        end

        def stale_session?(output) = output.include?("No conversation found with session ID")
        def result_event?(event) = event.key?("result")
        # The result names each model that the run used. The main model comes first.
        def model(output) = result_event(output)["modelUsage"]&.keys&.first

        # A tool_use block, then a tool_result block with the same ID.
        def transcript_calls(id)
          blocks = jsonl(transcript_path(id)).flat_map { |event| Array(event.dig("message", "content")).grep(Hash) }
          sizes = result_sizes(blocks)
          blocks.select { |b| b["type"] == "tool_use" }
                .map { |b| [b["name"], b.dig("input", "command"), sizes[b["id"]]] }
        end

        def result_sizes(blocks)
          blocks.select { |b| b["type"] == "tool_result" }.to_h { |b| [b["tool_use_id"], b["content"].to_s.size] }
        end

        def transcript_path(id) = Dir.glob(File.join(Dir.home, ".claude", "projects", "*", "#{id}.jsonl")).first
      end
    end
  end
end
