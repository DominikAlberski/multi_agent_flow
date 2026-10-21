# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "harness"

module Maf
  module Shared
    # FlowFiles finds the files of the flow in a worktree. A branch from before
    # maf untrack still tracks them, and maf rewrites them in each worktree.
    module FlowFiles
      def self.path?(path) = path.start_with?(".maf/") || Harness.all.flat_map(&:runtime_files).include?(path)

      # Only a change that a merge of TARGET deletes is discarded. Returns true when no change is left.
      def self.discard(dir, target)
        paths = changed(dir)
        return true if paths.empty?
        return false unless discardable?(dir, target, paths)

        system("git", "-C", dir, "checkout", "-q", "HEAD", "--", *paths)
      end

      def self.discardable?(dir, target, paths)
        paths.all? { |path| path?(path) } && git(dir, "ls-tree", "-r", "--name-only", target, "--", *paths).empty?
      end

      def self.tracked?(dir) = !git(dir, "ls-files", "--", ".maf").empty?
      def self.changed(dir) = git(dir, "diff", "--name-only", "HEAD")
      def self.git(dir, *args) = IO.popen(["git", "-C", dir, *args], err: File::NULL, &:readlines).map(&:chomp)
    end
  end
end
