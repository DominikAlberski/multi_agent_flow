# frozen_string_literal: true

module Maf
  module Migrate
    # Rewrites changes the old paths inside files that stay in place or move.
    # The files are the taskrc, the worker registry, and the Claude settings.
    class Rewrites
      def initialize(project)
        @project = File.realpath(project)
      end

      def steps
        [taskrc, workers, claude_settings].compact
      end

      private

      # data.location of the taskrc holds the absolute path of the task database.
      def taskrc
        rewrite(".maf/coordination/taskrc", [["#{@project}/coordination", "#{@project}/.maf/coordination"]])
      end

      def workers
        rewrite(".maf/coordination/workers.json", [["#{@project}/.worktrees", "#{@project}/.maf/worktrees"]])
      end

      def claude_settings
        rewrite(".claude/settings.json", %w[next-task board-watch].map { |name| hook_paths(name) })
      end

      def hook_paths(name)
        ["ruby coordination/harness-hooks/#{name}.rb", "ruby .maf/coordination/harness-hooks/#{name}.rb"]
      end

      def rewrite(rel, pairs)
        file = find(rel)
        return unless file && pairs.any? { |old, _| File.read(file).include?(old) }

        Step.new("edit   #{rel}", -> { apply(rel, pairs) })
      end

      def apply(rel, pairs)
        file = find(rel)
        File.write(file, pairs.reduce(File.read(file)) { |text, (old, new)| text.gsub(old, new) })
      end

      # The folder moves in an earlier step. The plan still sees the old place.
      def find(rel)
        [File.join(@project, rel), File.join(@project, rel.delete_prefix(".maf/"))].find { |file| File.file?(file) }
      end
    end
  end
end
