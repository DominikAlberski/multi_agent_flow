# frozen_string_literal: true

require "fileutils"
require_relative "shared/git_exclude"

# EnvExclude hides the .maf/env.sh of a worktree from git.
# .maf/env.sh holds absolute host paths and must never be committed.
# Git has no per-worktree exclude, so add the path to the shared local exclude.
# coord worktree does the same (see Coord::Worktree#exclude_env_file).
# An excluded file does not block git worktree remove.
module EnvExclude
  FILE = ".maf/env.sh"

  def self.add(dir)
    path = Maf::Shared::GitExclude.path(dir)
    return if path.nil? || (File.exist?(path) && File.read(path).lines.map(&:strip).include?(FILE))

    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |file| file.puts(FILE) }
  end
end
