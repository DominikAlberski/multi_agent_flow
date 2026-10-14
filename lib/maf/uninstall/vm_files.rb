# frozen_string_literal: true

module Maf
  module Uninstall
    # VmFiles removes the gem file that maf vm create copied into .maf/vm/.
    class VmFiles
      def initialize(project) = @dir = File.join(project, ".maf", "vm")

      def steps
        return [] unless Dir.exist?(@dir)

        [Step.new("remove #{@dir} (the gem file for maf vm)", -> { FileUtils.rm_rf(@dir) })]
      end
    end
  end
end
