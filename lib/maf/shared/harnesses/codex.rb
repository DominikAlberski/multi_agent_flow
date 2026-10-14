# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "../harness/traits"

module Maf
  module Shared
    module Harnesses
      # Codex. It has no agent flag, so a fresh session gets the role file in
      # front of the prompt. Codex returns a long tool call to the model about
      # every 30 seconds, so an idle agent runs `coord await`, and the stop
      # hook in .codex/hooks.json waits for work outside the model.
      class Codex < Harness::Base
        include Harness::PrependsRole

        def role_dir = ".codex/prompts"

        def role_template = <<~ERB
          <!-- >>> multi-agent-flow >>> -->
          # <%= title %>

          <% if model -%>
          > Model: `<%= model %>` (Codex sets the model at launch: `codex -m <%= model %>`)
          <% end -%>
          <%= prompt %>
        ERB

        def model_hint(model) = "codex -m #{model}"
        def wait = :await
        def home = ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex"))
        def sandbox_dirs = [home]
        PROTECTED = %w[config.toml hooks.json hooks rules skills plugins prompts packages AGENTS.md
                       AGENTS.override.md].freeze
        def sandbox_protected = in_dir(home, PROTECTED)
        def sandbox_placeholders = super - [File.join(home, "packages")]
        STATE = %w[sessions archived_sessions memories log logs* *.sqlite* history.jsonl* session_index.jsonl*
                   auth.json* models_cache.json* version.json* installation_id* .sqlite-maintenance.lock tmp .tmp
                   shell_snapshots attachments thread-writer-locks tui-*].freeze
        def sandbox_state = in_dir(home, STATE)
        PROJECT = %w[.codex/config.toml .codex/hooks.json .codex/hooks .codex/rules .codex/prompts
                     .agents/skills].freeze
        def sandbox_project = PROJECT
        def vm_install = "sudo npm install -g @openai/codex"
        def vm_credentials = [Harness::VmCredential.file(File.join(home, "auth.json"), ".codex/auth.json")]

        def sandboxed(cmd)
          return cmd if cmd.include?("--dangerously-bypass-approvals-and-sandbox")

          [cmd.first, "--sandbox", "danger-full-access", *cmd.drop(1)]
        end

        # Codex keeps the model list of the account in a cache file. Hidden models are internal.
        def models
          models = JSON.parse(File.read(File.join(Dir.home, ".codex", "models_cache.json"))).fetch("models")
          models.select { |m| m["visibility"] == "list" }.map { |m| m["slug"] }
        rescue SystemCallError, JSON::ParserError, KeyError, NoMethodError
          nil
        end

        # Codex keeps MCP servers in a global user file. maf does not edit it.
        def mcp_command(server, vault) = "codex mcp add #{server} -- ruby #{vault} mcp"

        def install_hooks(project)
          %w[next-task.rb session-guard.rb].each { |name| Flow::HookFiles.install(project, name) }
          runtime_hooks(project)
          Flow::LegacyCodexHook.new.remove
          nil
        end

        def runtime_hooks(worktree) = Flow::CodexHooks.new(worktree).install
        def runtime_files = [".codex/hooks.json"]
        def cleaners(project) = [Uninstall::CodexHooks.new(project)]

        # An older maf tracked the role files. A hooks file with only the flow hooks belongs to the flow.
        def untrack_paths(root, tracked)
          hooks = tracked.call(".codex/hooks.json").select { |file| Flow::CodexHooks.flow_only?(File.join(root, file)) }
          tracked.call(role_dir) + hooks
        end

        def launch(role, model)
          abort "setup_agent: #{role_path(role)} missing." unless File.exist?(role_path(role))

          warn_untrusted
          ["codex", "--add-dir", File.join(Project.root, ".maf", "coordination"), *model_flag(model),
           File.read(role_path(role))]
        end

        UNTRUSTED = "maf: Codex does not trust the hooks in %<file>s yet. Without the hooks, the session " \
                    "records no token usage, and coord await cannot wake it. The sandbox cannot save the trust: " \
                    "start codex once in %<root>s without the sandbox, and trust the hooks when Codex asks."

        def warn_untrusted
          root = File.realpath(Project.root)
          hooks = File.join(root, ".codex", "hooks.json")
          config = File.join(home, "config.toml")
          trusted = File.exist?(config) && File.read(config).include?("#{hooks}:stop:")
          warn format(UNTRUSTED, file: hooks, root: root) if File.exist?(hooks) && !trusted
        end

        # The OpenAI cache of Codex is best effort: a probe missed it after 5 idle minutes.
        def cache_window = 300

        def build_command(config, prompt, session_id)
          cmd = %w[codex exec] + (session_id ? ["resume"] : [])
          cmd += %w[--json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox]
          cmd += model_flag(config.model, "-m")
          cmd += lean_flags if config.lean
          cmd + resume(session_id) + [first_prompt(config.role, prompt, session_id)]
        end

        def lean_flags = CodexLean.flags(home)
        def stale_session?(output) = output.include?("no rollout found for thread id")

        def result_text(output)
          Harness::Events.last(output) { |event| event.dig("item", "type") == "agent_message" }.dig("item", "text")
        end

        def session_id(output)
          present(Harness::Events.last(output) { |event| event["type"] == "thread.started" }["thread_id"])
        end

        # Codex reports the usage of each turn in a turn.completed event.
        def usage(output)
          turns = Harness::Events.all(output).select { |event| event["type"] == "turn.completed" }
          Harness::Usage.sum(turns.filter_map { |event| Harness::Usage.normalize(event["usage"]) })
        end

        def transcript_calls(id)
          path = Dir.glob(File.join(Dir.home, ".codex", "sessions", "**", "rollout-*#{id}.jsonl")).first
          CodexTranscript.calls(jsonl(path).map { |event| event["payload"] || {} })
        end
      end

      # CodexLean drops the parts of the user's Codex setup that a one-shot run
      # does not use. Each one adds tool schemas, skill lists, or MCP calls
      # to every model call. Only the graphify server of this project stays.
      module CodexLean
        FEATURES = %w[plugins apps browser_use computer_use multi_agent].freeze
        SERVER = /^\[mcp_servers\.([\w-]+)\]\s*$/

        def self.flags(home) = FEATURES.flat_map { |name| ["--disable", name] } + servers(home).flat_map { |s| off(s) }
        def self.off(server) = ["-c", "mcp_servers.#{server}.enabled=false"]
        def self.keep = "graphify-#{File.basename(Project.root)}"

        def self.servers(home)
          path = File.join(home, "config.toml")
          File.exist?(path) ? File.read(path).scan(SERVER).flatten.uniq - [keep] : []
        end
      end

      # CodexTranscript reads the tool calls of a Codex session: a
      # custom_tool_call or function_call, then its output with the same call_id.
      module CodexTranscript
        def self.calls(payloads)
          sizes = output_sizes(payloads)
          payloads.select { |p| %w[custom_tool_call function_call].include?(p["type"]) }
                  .map { |p| [p["name"], command(p), sizes[p["call_id"]]] }
        end

        def self.output_sizes(payloads)
          payloads.select { |p| p["type"].to_s.end_with?("_output") }.to_h { |p| [p["call_id"], p["output"].to_s.size] }
        end

        def self.command(payload)
          text = (payload["input"] || payload["arguments"]).to_s
          text[/cmd["']?\s*:\s*["']((?:[^"'\\]|\\.)*)/, 1] || text
        end
      end
    end
  end
end
