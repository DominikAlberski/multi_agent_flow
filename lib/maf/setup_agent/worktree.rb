# frozen_string_literal: true

module SetupAgent
  class Worktree
    # All worktrees live inside the project under .worktrees/<slug>.
    # This must match Coord::Worktree.dir_for; scripts/check.rb enforces it.
    WORKTREES_DIR = ".worktrees"

    def self.dir_for(root, slug)
      File.join(root, WORKTREES_DIR, slug)
    end

    # `coord worktree` is idempotent. Run it also for an existing worktree,
    # so the worktree gets runtime files that were added after it was created.
    # MAF_HARNESS tells coord which harness starts the worker, so coord checks
    # the role file of that harness only.
    def self.ensure(role, worker_id, harness)
      dir = dir_for(Dir.pwd, "#{role}-#{worker_id}")
      abort "setup_agent: ./coord worktree failed" unless system({ "MAF_HARNESS" => harness }, "./coord", "worktree", role, worker_id)
      new(dir)
    end

    def initialize(dir)
      @dir = dir
    end

    def dir
      @dir
    end

    def export_env!
      path = File.join(@dir, "coord-env.sh")
      File.readlines(path).each { |line| set_env(line) } if File.exist?(path)
    end

    private

    def set_env(line)
      return unless line.chomp =~ /\Aexport (\w+)=(.+)\z/

      ENV[Regexp.last_match(1)] = Regexp.last_match(2)
    end
  end
end
