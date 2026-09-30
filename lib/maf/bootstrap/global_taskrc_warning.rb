# frozen_string_literal: true

module Bootstrap
  # GlobalTaskrcWarning warns when an older install left the UDA block in the
  # user's global ~/.taskrc. Earlier versions of this installer shared one
  # Taskwarrior database across every project. The warning stops old tasks
  # from staying stranded there without notice.
  class GlobalTaskrcWarning
    def initialize(project)
      @project = project
    end

    def run
      return unless File.exist?(global) && File.read(global).include?(MARKER)
      return if same_file?(global, @project.taskrc_path)

      puts format(MIGRATION_NOTE, taskrc: global, project: @project.target, project_name: File.basename(@project.target))
    end

    private

    def global
      ENV.fetch("TASKRC", File.join(Dir.home, ".taskrc"))
    end

    def same_file?(first, second)
      File.exist?(first) && File.exist?(second) && File.identical?(first, second)
    end
  end
end
