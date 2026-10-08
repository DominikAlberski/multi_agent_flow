# frozen_string_literal: true

module Maf
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
        separator = File.size(file).zero? ? "" : "\n"
        File.write(file, "#{separator}data.location=#{@project.taskdata_path}\n", mode: "a")
        true
      end

      def write_exclude(_file, _source = nil)
        LocalExclude.add(@project.target, *EXCLUDED)
        true
      end

      def merge_hook(file, source) = HookMerger.new(@project).merge(file, source)

      def configure_claude_settings(file, _source = nil)
        @claude.configure(file)
      end
    end
  end
end
