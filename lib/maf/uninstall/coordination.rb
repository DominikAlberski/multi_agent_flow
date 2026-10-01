# frozen_string_literal: true

module Uninstall
  class Coordination
    def initialize(project) = @dir = File.join(project, ".maf", "coordination")

    def steps
      return [] unless Dir.exist?(@dir)

      [Step.new("remove #{@dir} (task board, messages, locks, hooks)", -> { FileUtils.rm_rf(@dir) })]
    end
  end
end
