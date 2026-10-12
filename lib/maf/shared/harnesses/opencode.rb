# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "open3"
require_relative "../harness/traits"

module Maf
  module Shared
    module Harnesses
      # opencode. `--agent` loads .opencode/agents/<role>.md. The board-watch
      # plugin in .opencode/plugins/ wakes an idle session. opencode merges the
      # file in OPENCODE_CONFIG with the project's opencode.json.
      class Opencode < Harness::Base
        def role_dir = ".opencode/agents"

        def role_template = <<~ERB
          ---
          # >>> multi-agent-flow >>>
          description: <%= description %>
          mode: all
          <% if model -%>
          model: <%= model %>
          <% end -%>
          temperature: 0.1
          permission:
            edit: <%= can_edit ? "allow" : "deny" %>
            bash: allow
            # Worktrees live inside the project. The board, the artifacts, and git
            # data are outside the worktree, so opencode would ask for each access.
            external_directory:
              "/tmp/*": allow
              "/private/tmp/*": allow
              "<%= project %>/.maf/*": allow
              "<%= project %>/.git/*": allow
            task:
              "*": deny
              explore: allow
          ---

          <%= prompt %>
        ERB

        def models
          return nil unless installed?

          out, status = Open3.capture2("opencode", "models", err: File::NULL)
          status.success? && !out.strip.empty? ? out.split : nil
        rescue SystemCallError
          nil
        end

        def wait = :watch

        # opencode keeps its data in the XDG folders. ~/.cache is open for each harness.
        DATA_DIRS = %w[.local/share/opencode .local/state/opencode .config/opencode].freeze
        def sandbox_dirs = DATA_DIRS.map { |dir| File.join(Dir.home, dir) }
        def vm_install = "curl -fsSL https://opencode.ai/install | bash"

        def mcp
          { file: ".maf/mcp/opencode.json", key: "mcp", schema: "https://opencode.ai/config.json",
            entry: { "type" => "local", "command" => Harness::VAULT_MCP, "enabled" => true } }
        end

        def legacy_mcp_file = "opencode.json"
        def bootstrap_dir = ".opencode"

        PLUGIN = ".opencode/plugins/board-watch.js"

        def runtime_hooks(worktree) = SetupAgent::RuntimeHooks.copy(worktree, "board-watch-opencode.js", PLUGIN)
        def runtime_files = [PLUGIN]
        def empty_dirs = [role_dir, File.dirname(PLUGIN), home_dir]

        # An older maf tracked the role files and the plugin.
        def untrack_paths(_root, tracked) = tracked.call(role_dir) + tracked.call(PLUGIN)

        def launch_env = config_env(flow_file("mcp", "opencode.json"))
        def run_env(config) = config_env(run_file(config, "mcp", "opencode.json"))
        def config_env(file) = File.exist?(file) ? { "OPENCODE_CONFIG" => file } : {}

        def launch(role, model)
          ["opencode", ".", "--agent", role, "--prompt", "Start your work loop now.", *model_flag(model)]
        end

        # `opencode run --format json`. The result event shape is not verified,
        # so the log shows no result text.
        def build_command(config, prompt, session_id)
          %w[opencode run --format json --agent] + [config.role] + model_flag(config.model, "-m") +
            resume(session_id, "--session") + [prompt]
        end

        # DeepSeek costs twice as much at peak hours.
        def peak_rate?(config) = configured_model(config).to_s.include?("deepseek")

        # The model of a run in the opencode order: --model, the agent file, the project config, the user config.
        CONFIG_MODEL = /^\s*"model"\s*:\s*"([^"]+)"/
        AGENT_MODEL = /\A---\n(?:(?!^---$).)*?^model:\s*(\S+)/m

        def configured_model(config)
          config.model || find(File.join(role_dir, "#{config.role}.md"), AGENT_MODEL) ||
            config_paths.lazy.filter_map { |path| find(path, CONFIG_MODEL) }.first
        end

        def config_paths
          home = File.join(ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config")), "opencode")
          %w[opencode.json opencode.jsonc] + %w[opencode.jsonc opencode.json].map { |name| File.join(home, name) }
        end

        def find(path, pattern) = File.exist?(path) ? File.read(path)[pattern, 1] : nil

        # opencode prints terminal escape codes and can glue two JSON objects
        # onto one line, so the session ID is matched on the start of an event
        # object (captured from a real run), not by parsing whole lines.
        EVENT_SESSION = /\{"type":"[\w.-]+","timestamp":\d+,"sessionID":"([^"]+)"/
        # Each model call ends with a step_finish event. Its tokens.input
        # excludes the cache reads and writes; reasoning is billed as output.
        STEP_FINISH = /\{"type":"step_finish".*/

        def stale_session?(output) = output.include?("Session not found")
        def session_id(output) = output.scan(EVENT_SESSION).flatten.last

        def steps(output)
          output.scan(STEP_FINISH).filter_map { |json| Harness::Events.parse(json)&.dig("part", "tokens") }
        end

        def usage(output) = Harness::Usage.sum(steps(output).map { |tokens| Harness::Usage.normalize(flat(tokens)) })
        def context(output) = steps(output).last&.then { |tokens| Harness::Usage.input(flat(tokens)) }

        def flat(tokens)
          { "input_tokens" => tokens["input"].to_i, "cache_read_input_tokens" => tokens.dig("cache", "read").to_i,
            "cache_creation_input_tokens" => tokens.dig("cache", "write").to_i,
            "output_tokens" => tokens["output"].to_i + tokens["reasoning"].to_i }
        end

        # opencode keeps its sessions in a SQLite database. The sqlite3 CLI reads it.
        def database = File.join(Dir.home, ".local", "share", "opencode", "opencode.db")

        def transcript_calls(id)
          return [] unless File.exist?(database) && id.match?(/\A[\w-]+\z/)

          out, status = Open3.capture2("sqlite3", "-readonly", "-json", database, transcript_query(id))
          status.success? && !out.empty? ? JSON.parse(out).map(&:values) : []
        rescue SystemCallError, JSON::ParserError
          []
        end

        def transcript_query(id)
          "select json_extract(data,'$.tool') tool, json_extract(data,'$.state.input.command') command, " \
            "length(json_extract(data,'$.state.output')) size from part where session_id = '#{id}' " \
            "and json_extract(data,'$.type') = 'tool'"
        end
      end
    end
  end
end
