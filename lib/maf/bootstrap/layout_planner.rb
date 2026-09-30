# frozen_string_literal: true

module Bootstrap
  # LayoutPlanner plans the coordination/ directories and their .gitkeep files.
  class LayoutPlanner
    def initialize(project)
      @project = project
    end

    def dirs
      SUBDIRS.map do |sub|
        dir = @project.path("coordination", sub)
        @project.action(Dir.exist?(dir) ? :skip : :mkdir, dir)
      end
    end

    def gitkeeps
      SUBDIRS.map do |sub|
        keep = @project.path("coordination", sub, ".gitkeep")
        @project.action(File.exist?(keep) ? :skip : :touch, keep)
      end
    end
  end
end
