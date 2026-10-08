# frozen_string_literal: true

module Uninstall
  # Removes the settings and the MCP config of the flow in .maf/, and the
  # local git excludes. The excludes keep the kept graphify-out/ dir, so
  # git does not show the generated files.
  class LocalFiles
    DIRS = [%w[.maf claude], %w[.maf mcp]].freeze

    def initialize(project) = @project = project

    def steps
      dirs = DIRS.map { |parts| File.join(@project, *parts) }.select { |dir| Dir.exist?(dir) }
      dirs.map { |dir| Step.new("remove #{dir}", -> { FileUtils.rm_rf(dir) }) } + exclude_steps
    end

    private

    def exclude_steps
      file = LocalExclude.exclude_path(@project)
      return [] if file.nil? || LocalExclude.listed(file).empty?

      [Step.new("remove the flow paths from #{file}", -> { keep_generated_dirs })]
    end

    def keep_generated_dirs
      kept = KEPT_DIRS.select { |dir| Dir.exist?(File.join(@project, dir)) }.map { |dir| "#{dir}/" }
      kept.empty? ? LocalExclude.remove(@project) : LocalExclude.replace(@project, kept)
    end
  end
end
