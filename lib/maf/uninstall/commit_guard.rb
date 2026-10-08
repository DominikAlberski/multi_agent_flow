# frozen_string_literal: true

module Maf
  module Uninstall
    # The commit guard lives in the git hooks dir, outside the working tree.
    class CommitGuard
      def initialize(project) = @project = project

      def steps
        path = Git.lines(@project, "rev-parse", "--git-path", "hooks").first
        hook = path && File.join(File.expand_path(path, @project), "pre-commit")
        hook && Owned.signed?(hook, Bootstrap::COMMIT_GUARD_SIGNATURE) ? [Owned.remove(hook)] : []
      end
    end
  end
end
