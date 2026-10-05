# frozen_string_literal: true

# untrack.rb - move an install that git tracks to the local layout.
require "json"
require_relative "uninstall"

module Maf
  # Untrack removes the flow from the project's git and keeps it working:
  # it untracks .maf/ and the harness links (the files stay on disk), removes
  # the flow blocks and entries from the project files, excludes the flow
  # locally, and runs maf update. The user reviews the change and commits it.
  class Untrack
    USAGE = "Usage: maf untrack [--check] [--yes]"
    PATHS = [".maf", ".opencode/agents", ".codex/prompts", Bootstrap::OPENCODE_PLUGIN].freeze

    def initialize(root, argv)
      @root = root
      @check = argv.include?("--check")
      @yes = argv.include?("--yes")
    end

    def run
      steps = plan
      return puts("maf: git tracks no file of the flow in #{@root}.") if steps.empty?

      steps.each { |step| puts "  #{step.label}" }
      @check ? puts("--check: no changes made.") : apply(steps)
    end

    private

    def plan
      cleaners = [Uninstall::MarkedFiles.new(@root, keep_rules: false), Uninstall::ClaudeSettings.new(@root),
                  Uninstall::McpEntries.new(@root)]
      [untrack_step, *cleaners.flat_map(&:steps)].compact
    end

    def untrack_step
      paths = tracked
      return nil if paths.empty?

      Uninstall::Step.new("git rm --cached (the files stay): #{paths.join(", ")}", -> { untrack(paths) })
    end

    def untrack(paths)
      system("git", "-C", @root, "rm", "-r", "-q", "--cached", "--", *paths, exception: true)
      LocalExclude.add(@root, *Bootstrap::EXCLUDED, *(paths - [".maf"]))
    end

    def apply(steps)
      abort "maf: cancelled" unless @yes || confirmed?
      steps.each(&:run)
      Dir.chdir(@root) { Maf.flow }
      puts "", "The flow left git. Review the change with `git status`, then commit it."
    end

    def confirmed?
      print "Untrack the items above? [y/N] "
      $stdin.gets.to_s.strip.match?(/\Ay(es)?\z/i)
    end

    # The tracked paths of the flow, and each tracked link into .maf/agents/.
    def tracked = (git_files(*PATHS).map { |path| top(path) } + agent_links + codex_hooks).uniq

    def top(path) = path.start_with?(".maf/") ? ".maf" : path

    def agent_links
      git_files(".claude/agents").select { |path| File.symlink?(File.join(@root, path)) && link_to_flow?(path) }
    end

    def link_to_flow?(path) = File.readlink(File.join(@root, path)).include?("#{Bootstrap::MAF_DIR}/agents")

    # A .codex/hooks.json with only the flow hooks belongs to the flow.
    def codex_hooks
      path = Flow::CodexHooks::FILE
      git_files(path).select { |file| (hook_commands(file) - Flow::CodexHooks::COMMANDS).empty? }
    end

    def hook_commands(file)
      data = JSON.parse(File.read(File.join(@root, file)))
      entries = data.fetch("hooks", {}).values.flatten
      entries.flat_map { |entry| entry.fetch("hooks", []) }.map { |hook| hook["command"] }
    rescue JSON::ParserError
      [nil]
    end

    def git_files(*paths) = IO.popen(["git", "-C", @root, "ls-files", "--", *paths], err: File::NULL, &:readlines)
                              .map(&:chomp)
  end
end
