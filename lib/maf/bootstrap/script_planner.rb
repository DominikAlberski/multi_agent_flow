# frozen_string_literal: true

module Bootstrap
  # ScriptPlanner plans every script copied from assets/: the top-level
  # scripts, the harness hooks, the opencode plugin, the commit guard, and
  # the doc-graph refresh with its git hooks.
  class ScriptPlanner
    COMMIT_GUARD = "git-hooks/pre-commit"
    HOOKS = [
      ["harness-hooks/next-task.rb", NEXT_TASK_HOOK_SIGNATURE],
      ["harness-hooks/next-task-hermes.sh", NEXT_TASK_HERMES_SIGNATURE],
      ["harness-hooks/board-watch.rb", BOARD_WATCH_SIGNATURE],
      ["harness-hooks/session-guard.rb", SESSION_GUARD_SIGNATURE],
      ["harness-hooks/context-watch.rb", CONTEXT_WATCH_SIGNATURE]
    ].freeze
    # Hook event name -> the asset source symbol that holds the block.
    DOC_GRAPH_HOOKS = { "post-commit" => :post_commit, "post-merge" => :post_merge }.freeze

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

    # Append the flow block to the post-commit and post-merge hooks. A foreign
    # hook (graphify installs one) stays; the flow owns only its block.
    def doc_graph_hooks
      DOC_GRAPH_HOOKS.map { |name, source| hook(name, source) }
    end

    # The opencode plugin wakes an idle opencode session. Like the Claude
    # hooks, it is installed only if the project has a .opencode/ dir.
    def opencode_plugin
      return [] unless Dir.exist?(@project.path(".opencode"))

      [script("harness-hooks/board-watch-opencode.js", OPENCODE_BOARD_WATCH_SIGNATURE, @project.path(OPENCODE_PLUGIN))]
    end

    # The commit guard blocks commits by roles with can_edit false. A foreign
    # pre-commit hook stays, even with --force: it may run the project checks.
    def commit_guard
      dest = commit_guard_path
      return [] unless dest

      status = commit_guard_status(dest)
      label = @project.refuse_label(status, dest, "a foreign pre-commit hook; the commit guard is off")
      [@project.action(status, dest, label, COMMIT_GUARD)]
    end

    private

    def script(name, signature, dest = @project.bin_path(name))
      status = @project.script_status(dest, name, signature)
      @project.action(status, dest, @project.refuse_label(status, dest), name)
    end

    def commit_guard_status(dest)
      return :create unless File.exist?(dest)
      return :refuse unless @project.ours?(dest, COMMIT_GUARD_SIGNATURE)

      @project.changed_script?(dest, COMMIT_GUARD) ? :update : :skip
    end

    def commit_guard_path
      hooks = git_hooks_dir
      hooks && File.join(hooks, "pre-commit")
    end

    def hook(name, source)
      dest = hook_path(name)
      return @project.action(:skip, "git hook #{name} (no git repository)") unless dest

      @project.action(hook_status(dest, source), dest, dest, source)
    end

    def hook_status(dest, source)
      return :merge_hook unless File.exist?(dest)
      return :skip if block_current?(dest, source)

      :merge_hook
    end

    def block_current?(dest, source)
      MarkedBlock.new(File.read(dest)).current?(@project.append_content(source))
    end

    def hook_path(name)
      hooks = git_hooks_dir
      hooks && File.join(hooks, name)
    end

    def git_hooks_dir
      path = IO.popen(["git", "-C", @project.target, "rev-parse", "--git-path", "hooks"], err: File::NULL, &:read).strip
      $?.success? && !path.empty? ? File.expand_path(path, @project.target) : nil
    end
  end
end
