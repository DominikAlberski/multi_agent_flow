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
      cleaners = [Uninstall::MarkedFiles.new(@root, keep_rules: false),
                  *Uninstall.harness_cleaners(@root, legacy_only: true), Uninstall::McpEntries.new(@root)]
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

    # The tracked files of .maf/, and the tracked paths of each harness (Harness#untrack_paths).
    def tracked
      harness_paths = Maf::Shared::Harness.all.flat_map { |harness| harness.untrack_paths(@root, method(:git_files)) }
      ((git_files(".maf").empty? ? [] : [".maf"]) + harness_paths).uniq
    end

    def git_files(*paths) = IO.popen(["git", "-C", @root, "ls-files", "--", *paths], err: File::NULL, &:readlines)
                              .map(&:chomp)
  end
end
