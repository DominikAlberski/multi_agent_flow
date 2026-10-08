# frozen_string_literal: true

module Maf
  module Bootstrap
    # LayoutPlanner plans the directories of the .maf/ folder.
    class LayoutPlanner
      def initialize(project)
        @project = project
      end

      def dirs
        [@project.path(MAF_DIR, "bin"), *SUBDIRS.map { |sub| @project.path(MAF_DIR, "coordination", sub) }].map do |dir|
          @project.action(Dir.exist?(dir) ? :skip : :mkdir, dir)
        end
      end
    end
  end
end
