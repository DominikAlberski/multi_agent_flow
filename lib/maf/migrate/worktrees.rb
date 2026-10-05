# frozen_string_literal: true

module Migrate
  # Worktrees moves each git worktree of .worktrees/ into .maf/worktrees/.
  # git worktree move keeps the link between the worktree and the repository.
  # The env file of a worktree moves to .maf/env.sh with the new paths.
  # Git excludes .maf/env.sh, so the worktree stays clean.
  class Worktrees
    ENV_BIN = "export MAF_BIN=%<bin>s\n" \
              "case \":$PATH:\" in *\":$MAF_BIN:\"*) ;; *) export PATH=\"$MAF_BIN:$PATH\" ;; esac\n"

    def initialize(project)
      @project = File.realpath(project)
    end

    def steps
      old_dirs.map do |dir|
        new = dir.sub("/.worktrees/", "/.maf/worktrees/")
        Step.new("move   #{rel(dir)} -> #{rel(new)} (git worktree move)", -> { move(dir, new) })
      end
    end

    private

    def old_dirs
      root = File.join(@project, ".worktrees", "")
      IO.popen(["git", "-C", @project, "worktree", "list", "--porcelain"], err: File::NULL, &:readlines)
        .filter_map { |line| line[/\Aworktree (.+)/, 1] }.select { |dir| dir.start_with?(root) }
    rescue Errno::ENOENT
      []
    end

    def move(old, new)
      FileUtils.mkdir_p(File.dirname(new))
      moved = system("git", "-C", @project, "worktree", "move", old, new)
      abort "migrate: git worktree move failed for #{old}" unless moved
      env_file(new)
      Dir.rmdir(File.join(@project, ".worktrees")) if Dir.empty?(File.join(@project, ".worktrees"))
    end

    # The old env file holds the absolute paths of the old coordination folder.
    def env_file(dir)
      old = File.join(dir, "coord-env.sh")
      return unless File.file?(old) && File.read(old).include?("COORD_DIR=")

      write_env(dir, converted(File.read(old)))
      EnvExclude.add(dir)
      FileUtils.rm(old)
    end

    def write_env(dir, text)
      FileUtils.mkdir_p(File.join(dir, ".maf"))
      File.write(File.join(dir, ".maf", "env.sh"), text)
    end

    def converted(text)
      text.gsub("#{@project}/coordination", "#{@project}/.maf/coordination") +
        format(ENV_BIN, bin: File.join(@project, ".maf", "bin"))
    end

    def rel(path) = path.delete_prefix("#{@project}/")
  end
end
