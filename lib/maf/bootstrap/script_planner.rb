# frozen_string_literal: true

module Bootstrap
  # ScriptPlanner plans every script copied from assets/: the top-level
  # scripts, the harness hooks, the opencode plugin, and the commit guard.
  class ScriptPlanner
    COMMIT_GUARD = "git-hooks/pre-commit"
    HOOKS = [
      ["harness-hooks/next-task.rb", NEXT_TASK_HOOK_SIGNATURE],
      ["harness-hooks/next-task-hermes.sh", NEXT_TASK_HERMES_SIGNATURE],
      ["harness-hooks/board-watch.rb", BOARD_WATCH_SIGNATURE]
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

    def vault
      dest = @project.path(@project.vault_script)
      status = @project.script_status(dest, "vault", VAULT_SIGNATURE)
      @project.action(status, dest, vault_label(status, dest), "vault")
    end

    def hooks
      HOOKS.map { |name, signature| script(name, signature, @project.path("coordination", name)) }
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

    def script(name, signature, dest = @project.path(name))
      status = @project.script_status(dest, name, signature)
      @project.action(status, dest, @project.refuse_label(status, dest), name)
    end

    def vault_label(status, dest)
      return @project.refuse_label(status, dest) if status == :refuse

      @project.vault_script == "vault-daemon" ? "#{dest} (vault/ is a directory; installing as vault-daemon instead)" : dest
    end

    def commit_guard_status(dest)
      return :create unless File.exist?(dest)
      return :refuse unless @project.ours?(dest, COMMIT_GUARD_SIGNATURE)

      @project.changed_script?(dest, COMMIT_GUARD) ? :update : :skip
    end

    def commit_guard_path
      hooks = IO.popen(["git", "-C", @project.target, "rev-parse", "--git-path", "hooks"], err: File::NULL, &:read).strip
      $?.success? && !hooks.empty? ? File.join(File.expand_path(hooks, @project.target), "pre-commit") : nil
    end
  end
end
