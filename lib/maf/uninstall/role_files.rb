# frozen_string_literal: true

module Maf
  module Uninstall
    # Removes the role files in .maf/agents/ and the symlink of each harness
    # folder that points there.
    class RoleFiles
      DIRS = %w[claude opencode codex].map { |harness| [".maf", "agents", harness] }.freeze

      def initialize(project, manifest)
        @project = project
        @manifest = manifest
      end

      def steps
        links.map { |path| Owned.remove(path) } + project_files.map { |path| Owned.remove(path) } +
          @manifest.hermes_skills.select { |path| Owned.marked?(path) }.map { |path| hermes_step(path) }
      end

      private

      def project_files
        DIRS.flat_map { |parts| Dir.glob(File.join(@project, *parts, "*.md")) }.select { |path| Owned.marked?(path) }
      end

      def links = folder_links + file_links

      def folder_links
        Flow::HARNESS_DIRS.filter_map do |harness, dir|
          path = File.join(@project, dir)
          path if File.symlink?(path) && File.readlink(path) == Flow::AgentLinks.target(harness)
        end
      end

      # The links of single role files in a harness folder with the user's own files.
      def file_links
        Flow::HARNESS_DIRS.flat_map do |harness, dir|
          Dir.glob(File.join(@project, dir, "*.md")).select { |path| file_link?(path, harness) }
        end
      end

      def file_link?(path, harness)
        File.symlink?(path) && File.readlink(path) == Flow::AgentLinks.file_target(harness, File.basename(path))
      end

      def hermes_step(path)
        Step.new("remove #{File.dirname(path)}", -> { FileUtils.rm(path) && Owned.prune(File.dirname(path)) })
      end
    end
  end
end
