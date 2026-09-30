# frozen_string_literal: true

module Bootstrap
  # Writer performs the planned actions. Every writer method takes
  # (path, source) and returns true when it changed something.
  class Writer
    def initialize(project)
      @project = project
      @claude = ClaudeSettings.new(project)
    end

    def apply(actions)
      actions.each { |act| apply_action(act) }
    end

    private

    def apply_action(act)
      writer = WRITERS[act[:kind]]
      return Bootstrap.say(@project.format_action(act)) unless writer

      send(writer, act[:path], act[:source]) && Bootstrap.say("done   #{act[:label]}")
    end

    def make_dir(dir, _source)
      FileUtils.mkdir_p(dir)
    end

    def touch_file(file, _source)
      FileUtils.touch(file)
    end

    def write_script(dest, name)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(File.join(@project.assets, name), dest)
      FileUtils.chmod("+x", dest)
      true
    end

    def write_taskrc(file, _source = nil)
      FileUtils.mkdir_p([File.dirname(file), @project.taskdata_path])
      File.write(file, "data.location=#{@project.taskdata_path}\n\n#{@project.append_content(:taskrc)}")
      true
    end

    # Add the missing data.location to a taskrc this tool already owns,
    # without touching the rest of the file. An old marked taskrc without it
    # would otherwise fall back to the user's global ~/.task.
    def upgrade_taskrc(file, _source = nil)
      FileUtils.mkdir_p(@project.taskdata_path)
      File.open(file, "a") do |io|
        io.puts unless io.size.zero?
        io.puts("data.location=#{@project.taskdata_path}")
      end
      true
    end

    def append_marked(file, source)
      FileUtils.touch(file)
      File.open(file, "a") { |io| io.puts; io.write(@project.append_content(source)); io.puts }
      true
    end

    def replace_marked(file, source)
      File.write(file, MarkedBlock.new(File.read(file)).replace(@project.append_content(source)))
      true
    end

    # Append or replace the flow block in a git hook. A hook we did not create
    # stays; a new hook gets a shebang and the executable bit.
    def merge_hook(file, source)
      block = @project.append_content(source)
      text = File.exist?(file) ? File.read(file) : "#!/bin/sh\n"
      text = text.include?(MARKER) ? MarkedBlock.new(text).replace(block) : appended(text, block)
      write_hook(file, text)
    end

    def appended(text, block) = "#{text.rstrip}\n\n#{block.chomp}\n"

    def write_hook(file, text)
      File.write(file, text)
      FileUtils.chmod("+x", file)
      true
    end

    # Drops the old contract block and any `@AGENTS.md` import: AGENTS.md
    # gets its own contract, and a self-import is a loop.
    def move_claude_md(file, _source = nil)
      text = MarkedBlock.new(File.read(file)).remove.lines.reject { |line| line.strip == "@AGENTS.md" }.join.strip
      append_text(@project.path("AGENTS.md"), text) unless text.empty?
      FileUtils.rm(file)
    end

    def append_text(file, text)
      old = File.exist?(file) ? File.read(file).rstrip : ""
      File.write(file, [old, text].reject(&:empty?).join("\n\n") + "\n")
    end

    def configure_claude_settings(file, _source = nil)
      @claude.configure(file)
    end
  end
end
