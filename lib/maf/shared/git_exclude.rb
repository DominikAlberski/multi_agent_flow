# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    # GitExclude finds the info/exclude file of a clone. Every worktree of the
    # repository shares this file. The path is nil outside a git repository.
    module GitExclude
      def self.path(dir)
        path = IO.popen(["git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"],
                        err: File::NULL, &:read).strip
        path.empty? ? nil : path
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
