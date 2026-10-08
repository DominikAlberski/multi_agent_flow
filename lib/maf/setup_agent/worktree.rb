# frozen_string_literal: true

require_relative "../shared/project"

module SetupAgent
  class Worktree
    COORD = ".maf/bin/coord"

    # coord creates the worktree with the same shared formula.
    def self.dir_for(root, slug) = Maf::Shared::Project.worktree_dir(root, slug)

    # `coord worktree` is idempotent. Run it also for an existing worktree,
    # so the worktree gets runtime files that were added after it was created.
    # MAF_HARNESS tells coord which harness starts the worker, so coord checks
    # the role file of that harness only.
    def self.ensure(role, worker_id, harness)
      dir = dir_for(Dir.pwd, "#{role}-#{worker_id}")
      abort "setup_agent: coord worktree failed" unless coord_worktree(role, worker_id, harness)
      new(dir)
    end

    def self.coord_worktree(role, worker_id, harness)
      system({ "MAF_HARNESS" => harness }, RbConfig.ruby, COORD, "worktree", role, worker_id)
    end

    def initialize(dir)
      @dir = dir
    end

    def dir
      @dir
    end

    def export_env!
      path = File.join(@dir, ".maf/env.sh")
      File.readlines(path).each { |line| set_env(line) } if File.exist?(path)
      ENV["PATH"] = [ENV["MAF_BIN"], ENV["PATH"]].compact.join(File::PATH_SEPARATOR)
    end

    private

    def set_env(line)
      return unless line.chomp =~ /\Aexport (\w+)=(.+)\z/

      ENV[Regexp.last_match(1)] = Regexp.last_match(2)
    end
  end
end
