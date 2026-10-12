# frozen_string_literal: true

module Maf
  module Uninstall
    # Removes the role files in .maf/agents/ and the symlink of each harness
    # folder that points there.
    class RoleFiles
      def initialize(project, manifest)
        @project = project
        @manifest = manifest
      end

      def steps
        links.map { |path| Owned.remove(path) } + project_files.map { |path| Owned.remove(path) } +
          @manifest.outside_role_files.select { |path| Owned.marked?(path) }.map { |path| outside_step(path) }
      end

      private

      def project_files
        Dir.glob(File.join(@project, ".maf", "agents", "*", "*.md")).select { |path| Owned.marked?(path) }
      end

      def links = folder_links + file_links

      def folder_links
        harnesses.filter_map do |harness|
          path = File.join(@project, harness.role_dir)
          path if File.symlink?(path) && File.readlink(path) == Flow::AgentLinks.target(harness.name)
        end
      end

      # The links of single role files in a harness folder with the user's own files.
      def file_links
        harnesses.flat_map do |harness|
          Dir.glob(File.join(@project, harness.role_dir, "*.md")).select { |path| file_link?(path, harness.name) }
        end
      end

      def file_link?(path, harness)
        File.symlink?(path) && File.readlink(path) == Flow::AgentLinks.file_target(harness, File.basename(path))
      end

      def harnesses = Maf::Shared::Harness.all.select(&:role_dir)

      # A role file outside the project lives in a folder of its own.
      def outside_step(path)
        Step.new("remove #{File.dirname(path)}", -> { FileUtils.rm(path) && Owned.prune(File.dirname(path)) })
      end
    end
  end
end
