# frozen_string_literal: true

# uninstall.rb - remove the multi-agent flow from a project.
#
# maf uninstall runs Uninstall::Runner. Options: --project DIR [--check] [--yes] [--force]
#
# Removes only what bootstrap.rb and flow.rb installed. A file must carry the
# tool signature or marker. A foreign file with the same name stays.
# Keeps graphify-out/ and obsidian/. Rebuilding them costs many agent runs,
# so the user deletes them by hand.
# Keeps worker/* branches. Keeps dirty worktrees unless --force is given.
# Keeps the global Codex and Hermes hooks. Other projects can use them.
require "fileutils"
require "json"
require "optparse"
require_relative "bootstrap"
require_relative "flow"

module Uninstall
  KEPT_DIRS = %w[graphify-out obsidian].freeze

  # Removed after all steps if empty. Children come before parents.
  EMPTY_DIRS = [%w[.claude agents], %w[.claude], %w[.opencode agents], %w[.opencode],
                %w[.codex prompts], %w[.codex], %w[.worktrees]].freeze

  GLOBAL_HOOKS = [File.join(Dir.home, ".codex", "hooks", "next-task.rb"),
                  File.join(Dir.home, ".hermes", "agent-hooks", "next-task.sh")].freeze

  # Step is one removal. --check prints the label and runs nothing.
  Step = Struct.new(:label, :work) do
    def run = work.call
  end

  module Owned
    def self.signed?(path, signature) = File.file?(path) && File.read(path).include?(signature)
    def self.marked?(path) = signed?(path, Bootstrap::MARKER)
    def self.prune(dir) = Dir.exist?(dir) && Dir.empty?(dir) && Dir.rmdir(dir)
    def self.remove(path) = Step.new("remove #{path}", -> { FileUtils.rm(path) })
  end

  module Git
    def self.lines(project, *args)
      IO.popen(["git", "-C", project, *args], err: File::NULL, &:readlines).map(&:chomp)
    rescue Errno::ENOENT
      []
    end
  end

  # The vault watcher runs detached. Stop it while its script still exists.
  class VaultWatcher
    def initialize(project) = @project = project

    def steps
      return [] unless File.exist?(File.join(@project, "coordination", "vault.pid")) && script

      [Step.new("stop vault watcher", -> { system(script, "stop", chdir: @project) })]
    end

    def script
      %w[vault vault-daemon].map { |name| File.join(@project, name) }
                            .find { |path| Owned.signed?(path, Bootstrap::VAULT_SIGNATURE) }
    end
  end

  class Worktrees
    def initialize(project, force)
      @project = project
      @force = force
    end

    def steps = paths.map { |dir| Step.new("remove worktree #{dir}", -> { remove(dir) }) }

    private

    def paths
      root = File.join(@project, ".worktrees", "")
      Git.lines(@project, "worktree", "list", "--porcelain")
         .filter_map { |line| line[/\Aworktree (.+)/, 1] }.select { |dir| dir.start_with?(root) }
    end

    def remove(dir)
      args = ["worktree", "remove", *("--force" if @force), dir]
      system("git", "-C", @project, *args, err: File::NULL) ||
        puts("kept   #{dir} (uncommitted changes; use --force to remove)")
    end
  end

  class Scripts
    SIGNATURES = { "coord" => Bootstrap::COORD_SIGNATURE, "setup_agent" => Bootstrap::SETUP_AGENT_SIGNATURE,
                   "dispatcher" => Bootstrap::DISPATCHER_SIGNATURE, "dashboard" => Bootstrap::DASHBOARD_SIGNATURE,
                   "vault" => Bootstrap::VAULT_SIGNATURE, "vault-daemon" => Bootstrap::VAULT_SIGNATURE }.freeze

    def initialize(project) = @project = project

    def steps
      SIGNATURES.map { |name, signature| [File.join(@project, name), signature] }
                .select { |path, signature| Owned.signed?(path, signature) }
                .map { |path, _| Owned.remove(path) }
    end
  end

  # The commit guard lives in the git hooks dir, outside the working tree.
  class CommitGuard
    def initialize(project) = @project = project

    def steps
      path = Git.lines(@project, "rev-parse", "--git-path", "hooks").first
      hook = path && File.join(File.expand_path(path, @project), "pre-commit")
      hook && Owned.signed?(hook, Bootstrap::COMMIT_GUARD_SIGNATURE) ? [Owned.remove(hook)] : []
    end
  end

  # .agent-flow.json lists the generated agents. Hermes skills live outside
  # the project, so only the manifest tells which ones belong to it.
  class Manifest
    def initialize(project)
      @project = project
      @path = File.join(project, ".agent-flow.json")
    end

    def steps = File.exist?(@path) ? [Owned.remove(@path)] : []

    def hermes_skills
      roles = data.fetch("agents", []).select { |a| a["harness"] == "hermes" }.map { |a| a["role"] }
      roles.map { |role| File.join(hermes_dir, "#{File.basename(@project)}-#{role}", "SKILL.md") }
    end

    private

    def hermes_dir = data.fetch("hermes_dir", Flow::DEFAULT_HERMES_DIR)

    def data
      @data ||= File.exist?(@path) ? (JSON.parse(File.read(@path)) rescue {}) : {}
    end
  end

  class RoleFiles
    DIRS = [%w[.claude agents], %w[.opencode agents], %w[.codex prompts]].freeze

    def initialize(project, manifest)
      @project = project
      @manifest = manifest
    end

    def steps
      project_files.map { |path| Owned.remove(path) } +
        @manifest.hermes_skills.select { |path| Owned.marked?(path) }.map { |path| hermes_step(path) }
    end

    private

    def project_files
      DIRS.flat_map { |parts| Dir.glob(File.join(@project, *parts, "*.md")) }.select { |path| Owned.marked?(path) }
    end

    def hermes_step(path)
      Step.new("remove #{File.dirname(path)}", -> { FileUtils.rm(path) && Owned.prune(File.dirname(path)) })
    end
  end

  # Removes the flow hooks from .claude/settings.json. Other hooks and
  # settings stay. The file goes only if nothing else is left in it.
  class ClaudeSettings
    COMMANDS = Bootstrap::CLAUDE_HOOKS.map { |_, hook| hook["command"] }.uniq.freeze

    def initialize(project) = @path = File.join(project, ".claude", "settings.json")

    def steps
      return [] unless File.exist?(@path) && strip(settings) != settings

      [Step.new("remove flow hooks from #{@path}", -> { clean })]
    end

    private

    def settings = (JSON.parse(File.read(@path)) rescue {})

    def clean
      data = strip(settings)
      data.empty? ? FileUtils.rm(@path) : File.write(@path, JSON.pretty_generate(data))
    end

    def strip(data)
      hooks = data.fetch("hooks", {}).transform_values { |entries| strip_event(entries) }.reject { |_, v| v.empty? }
      hooks.empty? ? data.except("hooks") : data.merge("hooks" => hooks)
    end

    def strip_event(entries)
      entries.map { |entry| entry.merge("hooks" => entry.fetch("hooks", []).reject { |h| ours?(h) }) }
             .reject { |entry| entry["hooks"].empty? }
    end

    def ours?(hook) = COMMANDS.include?(hook["command"])
  end

  # Removes the marked block from AGENTS.md and .gitignore. Text
  # outside the block stays. A file with nothing left goes. .gitignore keeps
  # the ignore rules for the kept graphify-out/ and obsidian/ dirs.
  class MarkedFiles
    FILES = %w[AGENTS.md .gitignore].freeze

    def initialize(project) = @project = project

    def steps
      FILES.map { |name| File.join(@project, name) }.select { |path| Owned.marked?(path) }
           .map { |path| Step.new("remove flow block from #{path}", -> { clean(path) }) }
    end

    private

    def clean(path)
      text = Bootstrap::MarkedBlock.new(File.read(path)).remove.rstrip
      text = [text, *(kept_rules(path) - text.lines.map(&:strip))].reject(&:empty?).join("\n")
      text.empty? ? FileUtils.rm(path) : File.write(path, "#{text}\n")
    end

    def kept_rules(path)
      return [] unless File.basename(path) == ".gitignore"

      KEPT_DIRS.select { |dir| Dir.exist?(File.join(@project, dir)) }.map { |dir| "#{dir}/" }
    end
  end

  class Coordination
    def initialize(project) = @dir = File.join(project, "coordination")

    def steps
      return [] unless Dir.exist?(@dir)

      [Step.new("remove #{@dir} (task board, messages, locks, hooks)", -> { FileUtils.rm_rf(@dir) })]
    end
  end

  # Tells the user what the uninstaller keeps on purpose.
  class Notes
    def initialize(project) = @project = project

    def lines
      [kept_dirs, branches, global_hooks].compact
    end

    private

    def kept_dirs
      dirs = KEPT_DIRS.select { |dir| Dir.exist?(File.join(@project, dir)) }
      "kept   #{dirs.map { |d| "#{d}/" }.join(", ")} (costly to rebuild; delete by hand)" if dirs.any?
    end

    def branches
      list = Git.lines(@project, "branch", "--list", "worker/*", "--format=%(refname:short)")
      "kept   branches #{list.join(", ")} (delete with git branch -D)" if list.any?
    end

    def global_hooks
      hooks = GLOBAL_HOOKS.select { |path| File.exist?(path) }
      "kept   global hooks #{hooks.join(", ")} (other projects can use them)" if hooks.any?
    end
  end

  class Runner
    USAGE = "Usage: maf uninstall [--check] [--yes] [--force]"

    def initialize(argv)
      @opts = {}
      OptionParser.new(USAGE) { |o| ["--project DIR", "--check", "--yes", "--force"].each { |f| o.on(f) } }
                  .parse!(argv, into: @opts)
    end

    def run
      steps = plan
      return finish("nothing to remove in #{project}") if steps.empty?

      steps.each { |step| say(step.label.gsub("#{project}/", "")) }
      @opts[:check] ? finish("check only; nothing removed") : apply(steps)
    end

    private

    def project
      abort USAGE unless @opts[:project] && Dir.exist?(@opts[:project])
      @project ||= File.realpath(@opts[:project])
    end

    def plan
      manifest = Manifest.new(project)
      [VaultWatcher.new(project), Worktrees.new(project, @opts[:force]), Scripts.new(project), CommitGuard.new(project),
       RoleFiles.new(project, manifest), ClaudeSettings.new(project), MarkedFiles.new(project),
       Coordination.new(project), manifest].flat_map(&:steps)
    end

    def apply(steps)
      abort "uninstall: cancelled" unless @opts[:yes] || confirmed?
      steps.each(&:run)
      EMPTY_DIRS.each { |parts| Owned.prune(File.join(project, *parts)) }
      finish("removed the multi-agent flow from #{project}")
    end

    def confirmed?
      print "Remove the items above? [y/N] "
      $stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)
    end

    def finish(message)
      Notes.new(project).lines.each { |line| say(line) }
      say(message)
    end

    def say(message) = puts("[multi-agent-flow] #{message}")
  end
end
