# frozen_string_literal: true

require "fileutils"
require_relative "shared/git_exclude"

module Maf
  # LocalExclude keeps the paths of the flow in the .git/info/exclude file of
  # the clone. The flow is a tool, not a part of the project, so nothing that
  # runs it goes into git. info/exclude is local to the clone, and every
  # worktree of the repository shares it. The paths sit in one marked block.
  module LocalExclude
    BEGIN_LINE = "# >>> multi-agent-flow >>>"
    END_LINE = "# <<< multi-agent-flow <<<"

    # Adds each path that the block does not list yet.
    def self.add(dir, *paths)
      file = exclude_path(dir)
      file && write(file, (listed(file) + paths).uniq)
    end

    def self.replace(dir, paths)
      file = exclude_path(dir)
      file && write(file, paths)
    end

    def self.remove(dir)
      file = exclude_path(dir)
      File.write(file, outside(File.read(file))) if file && File.exist?(file)
    end

    def self.listed(file)
      lines = File.exist?(file) ? File.read(file).lines.map(&:chomp) : []
      first = lines.index(BEGIN_LINE)
      last = lines.index(END_LINE)
      first && last ? lines[(first + 1)...last] : []
    end

    def self.write(file, paths)
      FileUtils.mkdir_p(File.dirname(file))
      text = File.exist?(file) ? outside(File.read(file)) : ""
      File.write(file, "#{text.chomp}#{"\n" unless text.strip.empty?}#{[BEGIN_LINE, *paths, END_LINE].join("\n")}\n")
    end

    def self.outside(text)
      lines = text.lines
      first = lines.index { |line| line.chomp == BEGIN_LINE }
      last = lines.index { |line| line.chomp == END_LINE }
      first && last ? (lines[0...first] + lines[(last + 1)..]).join : text
    end

    def self.exclude_path(dir) = Maf::Shared::GitExclude.path(dir)
  end
end
