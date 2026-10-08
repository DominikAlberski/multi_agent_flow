# frozen_string_literal: true

module Maf
  module Bootstrap
    # TextPlanner plans the taskrc and the local git excludes. The flow never
    # writes into a file that git tracks: it is a tool, not a part of the project.
    class TextPlanner
      def initialize(project)
        @project = project
      end

      def taskrc
        file = @project.taskrc_path
        status = taskrc_status(file)
        label = status == :refuse ? @project.refuse_label(status, file) : "#{file} (Taskwarrior UDAs, project-local)"
        @project.action(status, file, label)
      end

      # .git/info/exclude hides the flow from git in this clone only.
      def exclude
        file = LocalExclude.exclude_path(@project.target)
        return [] unless file

        status = (EXCLUDED - LocalExclude.listed(file)).empty? ? :skip : :local_exclude
        [@project.action(status, file, "#{file} (local git excludes)")]
      end

      private

      # Never overwrite a taskrc this tool did not create: it may point at a
      # real Taskwarrior database. A marked taskrc from an older install that
      # has no data.location is upgraded in place, not rewritten.
      def taskrc_status(file)
        return :create_taskrc unless File.exist?(file)
        return :create_taskrc if @project.force? && !@project.ours?(file, MARKER)
        return :refuse unless @project.ours?(file, MARKER)

        File.read(file).match?(/^data\.location=/) ? :skip : :upgrade_taskrc
      end
    end
  end
end
