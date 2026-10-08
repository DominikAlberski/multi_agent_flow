# frozen_string_literal: true

module Maf
  module Bootstrap
    # GitHookPlanner plans the git hooks: the commit guard, and the flow block
    # in the post-commit and post-merge hooks.
    class GitHookPlanner
      COMMIT_GUARD = "git-hooks/pre-commit"
      # Hook event name -> the asset source symbol that holds the block.
      DOC_GRAPH_HOOKS = { "post-commit" => :post_commit, "post-merge" => :post_merge }.freeze

      def initialize(project)
        @project = project
      end

      # The commit guard blocks commits by roles with can_edit false. A foreign
      # pre-commit hook stays, even with --force: it may run the project checks.
      def commit_guard
        dest = hook_path("pre-commit")
        return [] unless dest

        status = commit_guard_status(dest)
        [@project.action(status, dest, @project.refuse_label(status, dest, FOREIGN_GUARD), COMMIT_GUARD)]
      end

      # Append the flow block to the post-commit and post-merge hooks. A foreign
      # hook (graphify installs one) stays; the flow owns only its block.
      def doc_graph_hooks
        DOC_GRAPH_HOOKS.map { |name, source| hook(name, source) }
      end

      private

      FOREIGN_GUARD = "a foreign pre-commit hook; the commit guard is off"

      def commit_guard_status(dest)
        return :create unless File.exist?(dest)
        return :refuse unless @project.ours?(dest, COMMIT_GUARD_SIGNATURE)

        @project.changed_script?(dest, COMMIT_GUARD) ? :update : :skip
      end

      def hook(name, source)
        dest = hook_path(name)
        return @project.action(:skip, "git hook #{name} (no git repository)") unless dest

        @project.action(hook_status(dest, source), dest, dest, source)
      end

      def hook_status(dest, source) = File.exist?(dest) && block_current?(dest, source) ? :skip : :merge_hook

      def block_current?(dest, source)
        MarkedBlock.new(File.read(dest)).current?(@project.append_content(source))
      end

      def hook_path(name)
        hooks = git_hooks_dir
        hooks && File.join(hooks, name)
      end

      def git_hooks_dir
        cmd = ["git", "-C", @project.target, "rev-parse", "--git-path", "hooks"]
        path = IO.popen(cmd, err: File::NULL, &:read).strip
        $?.success? && !path.empty? ? File.expand_path(path, @project.target) : nil
      end
    end
  end
end
