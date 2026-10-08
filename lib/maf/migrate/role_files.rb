# frozen_string_literal: true

module Maf
  module Migrate
    # RoleFiles moves the role files of the flow from the folders of the
    # harnesses into .maf/agents/<harness>/. A file without the marker stays.
    # The regeneration step then replaces an empty harness folder with a symlink.
    class RoleFiles
      def initialize(project)
        @project = project
      end

      def steps
        Flow::HARNESS_DIRS.flat_map { |harness, dir| files(dir).map { |file| step(harness, dir, file) } }
      end

      private

      def files(dir)
        folder = File.join(@project, dir)
        return [] if File.symlink?(folder)

        Dir.glob(File.join(folder, "*.md")).select { |file| File.read(file).include?(Bootstrap::MARKER) }
      end

      def step(harness, dir, file)
        new = File.join(@project, ".maf", "agents", harness, File.basename(file))
        label = "move   #{dir}/#{File.basename(file)} -> .maf/agents/#{harness}/#{File.basename(file)}"
        return Step.new("keep   #{dir}/#{File.basename(file)} (the new file exists)", -> {}) if File.exist?(new)

        Step.new(label, -> { FileUtils.mkdir_p(File.dirname(new)) && FileUtils.mv(file, new) })
      end
    end
  end
end
