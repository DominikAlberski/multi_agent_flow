# frozen_string_literal: true

module Bootstrap
  # ScriptPlanner plans every script copied from assets/: the top-level
  # scripts, the harness hooks, the opencode plugin, and the doc-graph
  # refresh. GitHookPlanner plans the git hooks.
  class ScriptPlanner
    HOOKS = [
      ["harness-hooks/next-task.rb", NEXT_TASK_HOOK_SIGNATURE],
      ["harness-hooks/next-task-hermes.sh", NEXT_TASK_HERMES_SIGNATURE],
      ["harness-hooks/board-watch.rb", BOARD_WATCH_SIGNATURE],
      ["harness-hooks/session-guard.rb", SESSION_GUARD_SIGNATURE],
      ["harness-hooks/context-watch.rb", CONTEXT_WATCH_SIGNATURE]
    ].freeze

    def initialize(project)
      @project = project
    end

    def coord
      script("coord", COORD_SIGNATURE)
    end

    def dispatcher
      script("dispatcher", DISPATCHER_SIGNATURE)
    end

    def dashboard
      script("dashboard", DASHBOARD_SIGNATURE)
    end

    def analyst
      script("analyst", ANALYST_SIGNATURE)
    end

    def vault
      script("vault", VAULT_SIGNATURE)
    end

    # env.sh puts .maf/bin on PATH. A worker runs `source .maf/env.sh`.
    def env
      script("env.sh", ENV_SIGNATURE, @project.path(MAF_DIR, "env.sh"))
    end

    def hooks
      HOOKS.map { |name, signature| script(name, signature, @project.path(MAF_DIR, "coordination", name)) }
    end

    # The doc-graph refresh script rebuilds the shared graph after a markdown
    # change. The git hooks start it.
    def doc_graph
      script("doc-graph-refresh", DOC_GRAPH_SIGNATURE)
    end

    # The opencode plugin wakes an idle opencode session. Like the Claude
    # hooks, it is installed only if the project has a .opencode/ dir.
    def opencode_plugin
      return [] unless Dir.exist?(@project.path(".opencode"))

      [script("harness-hooks/board-watch-opencode.js", OPENCODE_BOARD_WATCH_SIGNATURE,
              @project.path(OPENCODE_PLUGIN))]
    end

    private

    def script(name, signature, dest = @project.bin_path(name))
      status = @project.script_status(dest, name, signature)
      @project.action(status, dest, @project.refuse_label(status, dest), name)
    end
  end
end
