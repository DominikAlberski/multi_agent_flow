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

    SH_SHEBANG = %r{\A#!\s*(?:/usr/bin/env\s+)?(?:\S*/)?(?:ba)?sh(?:\s|\z)}

    def merge_hook(file, source)
      return skip_foreign_hook(file) if foreign_interpreter?(file)

      block = @project.append_content(source)
      body = File.exist?(file) ? MarkedBlock.new(File.read(file)).remove : "#!/bin/sh\n"
      write_hook(file, prepend_block(body, block))
    end

    def foreign_interpreter?(file)
      return false unless File.exist?(file)

      first = File.open(file, &:gets).to_s
      first.start_with?("#!") && !first.match?(SH_SHEBANG)
    end

    def skip_foreign_hook(file)
      Bootstrap.say("skip   #{file}: foreign hook with a non-sh shebang, doc-graph refresh is off")
      false
    end

    def prepend_block(body, block)
      shebang, rest = split_shebang(body)
      "#{shebang}#{block.chomp}\n#{rest.lstrip}"
    end

    def split_shebang(body)
      lines = body.lines
      return ["", body] unless lines.first&.start_with?("#!")

      [lines.first, lines[1..].join]
    end

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
