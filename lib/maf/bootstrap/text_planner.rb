# frozen_string_literal: true

module Bootstrap
  # TextPlanner plans the taskrc, AGENTS.md, and .gitignore changes.
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

    # Claude Code reads AGENTS.md only when the project has no CLAUDE.md.
    # Move each CLAUDE.md into AGENTS.md, so every harness reads one file.
    def claude_md
      CLAUDE_MD_FILES.map { |name| @project.path(name) }.select { |file| File.file?(file) }
                     .map { |file| @project.action(:move_claude_md, file, "#{file} (move into AGENTS.md)") }
    end

    # AGENTS.md is the only instruction file. Every harness reads it.
    def contracts
      file = @project.path("AGENTS.md")
      [@project.action(block_status(file, :contract), file, "#{file} (agent contract)", :contract)]
    end

    def gitignore
      file = @project.path(".gitignore")
      @project.action(block_status(file, :gitignore), file, "#{file} (ignore rules)", :gitignore)
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

    # A marked block is owned by this tool. When the shipped block changed
    # (new ignore rules, new commands in the contract), replace the old block
    # in place so existing installs pick it up. Text outside the block stays.
    def block_status(file, source)
      return :append unless @project.marked?(file)

      MarkedBlock.new(File.read(file)).current?(@project.append_content(source)) ? :skip : :replace
    end
  end
end
