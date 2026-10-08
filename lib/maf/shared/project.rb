# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

require "json"

module Maf
  module Shared
    # Project finds the main checkout from any worktree. `git rev-parse
    # --git-common-dir` returns the main repo's .git dir (relative at the root,
    # absolute in a worktree), so its parent is the main checkout.
    module Project
      MANIFEST = ".maf/config.json"
      # All worktrees live inside the project, so agents need no access outside it.
      WORKTREES_DIR = ".maf/worktrees"

      def self.root
        common = IO.popen(%w[git rev-parse --git-common-dir], err: File::NULL, &:read).to_s.strip
        common.empty? ? Dir.pwd : File.dirname(File.expand_path(common))
      end

      def self.manifest
        JSON.parse(File.read(File.join(root, MANIFEST)))
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end

      # coord creates the worktree of a worker here, and maf start finds it here.
      def self.worktree_dir(root, slug) = File.join(root, WORKTREES_DIR, slug)
    end
  end
end
