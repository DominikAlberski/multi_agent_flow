# frozen_string_literal: true

require "open3"

module Bootstrap
  # MemoryBranch keeps the work memory in git with no noise in the project
  # history (ADR 0006). graphify-out/memory/ is a worktree of the orphan branch
  # maf/memory. The branch shares no history with the project branches, so a
  # note never shows in a pull request. A new clone takes the branch from
  # origin. The notes of an older install move into the worktree. When git
  # fails, the folder stays a plain folder and the flow works as before.
  class MemoryBranch
    BRANCH = "maf/memory"
    DIR = File.join(GRAPH_DIR, "memory")
    START = "memory: start the work memory of the flow"
    ADOPT = "memory: add the notes of an older install"

    def initialize(project) = @project = project

    def setup
      return if !repo? || File.exist?(path(DIR, ".git"))

      done = (local? || fetched? || created?) && checkout
      Bootstrap.say(done ? "done   #{DIR} is a worktree of branch #{BRANCH}" : "skip   #{BRANCH} (git failed)")
    end

    private

    # A project folder inside another repository has no repository of its own.
    def repo? = out("rev-parse", "--show-toplevel") == @project.target
    def local? = git("show-ref", "--verify", "--quiet", "refs/heads/#{BRANCH}")
    def fetched? = git("fetch", "-q", "origin", "#{BRANCH}:#{BRANCH}")

    # An orphan commit of the empty tree. It needs no checkout.
    def created?
      tree = out("hash-object", "-w", "-t", "tree", File::NULL)
      commit = out("commit-tree", tree, "-m", START)
      !commit.empty? && git("branch", BRANCH, commit)
    end

    # The notes of an older install wait in a side folder while git adds the worktree.
    def checkout
      old = "#{path(DIR)}.old"
      FileUtils.mv(path(DIR), old) if Dir.exist?(path(DIR))
      FileUtils.mkdir_p(path(GRAPH_DIR))
      git("worktree", "add", "-q", path(DIR), BRANCH).tap { |added| restore(old, added) }
    end

    def restore(old, added)
      return unless Dir.exist?(old)

      added ? adopt(old) : FileUtils.mv(old, path(DIR))
    end

    def adopt(old)
      Dir.children(old).each { |name| FileUtils.mv(File.join(old, name), path(DIR, name)) }
      FileUtils.rm_rf(old)
      git_in(path(DIR), "add", "-A") && git_in(path(DIR), "commit", "-q", "-m", ADOPT)
    end

    def git(*args) = git_in(@project.target, *args)
    def git_in(dir, *args) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)

    def out(*args)
      text, status = Open3.capture2("git", "-C", @project.target, *args, err: File::NULL)
      status.success? ? text.strip : ""
    end

    def path(*parts) = @project.path(*parts)
  end
end
