# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

require "open3"

module Maf
  module Shared
    # GitExclude finds the info/exclude file of a clone. Every worktree of the
    # repository shares this file. The path is nil outside a git repository.
    module GitExclude
      NOT_FOUND = "maf: no git exclude file for %s. Git can show the flow files as untracked."

      def self.path(dir)
        out = git_path(dir)
        return File.expand_path(out, dir) unless out.empty?

        warn format(NOT_FOUND, dir)
      end

      # --path-format=absolute needs git 2.31. Without it, git can give a path
      # relative to dir, so the caller makes it absolute.
      def self.git_path(dir)
        out, status = Open3.capture2("git", "-C", dir, "rev-parse", "--git-path", "info/exclude", err: File::NULL)
        status.success? ? out.strip : ""
      rescue Errno::ENOENT
        ""
      end
    end
  end
end
