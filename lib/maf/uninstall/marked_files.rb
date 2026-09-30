# frozen_string_literal: true

module Uninstall
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
end
