# frozen_string_literal: true

module Uninstall
  # DocGraphHooks removes the flow block from the post-commit and post-merge
  # hooks. A hook with nothing left but its shebang goes.
  class DocGraphHooks
    EVENTS = %w[post-commit post-merge].freeze

    def initialize(project) = @project = project

    def steps
      EVENTS.map { |event| path(event) }.compact.select { |hook| Owned.marked?(hook) }
            .map { |hook| Step.new("remove flow block from #{hook}", -> { clean(hook) }) }
    end

    private

    def path(event)
      hooks = Git.lines(@project, "rev-parse", "--git-path", "hooks").first
      hooks && File.join(File.expand_path(hooks, @project), event)
    end

    def clean(hook)
      text = Bootstrap::MarkedBlock.new(File.read(hook)).remove
      return drop(hook) if foreign_lines(text).empty?

      File.write(hook, "#{text.strip}\n")
    end

    def foreign_lines(text)
      text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#!") }
    end

    def drop(hook) = FileUtils.rm_f(hook)
  end
end
