# frozen_string_literal: true

module Uninstall
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
end
