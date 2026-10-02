# frozen_string_literal: true

module Uninstall
  class Worktrees
    def initialize(project, force)
      @project = project
      @force = force
    end

    def steps = paths.map { |dir| Step.new("remove worktree #{dir}", -> { remove(dir) }) }

    private

    def paths
      root = File.join(@project, ".maf/worktrees", "")
      Git.lines(@project, "worktree", "list", "--porcelain")
         .filter_map { |line| line[/\Aworktree (.+)/, 1] }.select { |dir| dir.start_with?(root) }
    end

    # A worktree that an older migrate moved has an env file that git does not exclude.
    def remove(dir)
      EnvExclude.add(dir)
      args = ["worktree", "remove", *("--force" if @force), dir]
      system("git", "-C", @project, *args, err: File::NULL) ||
        puts("kept   #{dir} (uncommitted changes; use --force to remove)")
    end
  end
end
