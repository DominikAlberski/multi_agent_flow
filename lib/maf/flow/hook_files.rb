# frozen_string_literal: true

module Maf
  module Flow
    # HookFiles copies a hook script from the assets and makes it executable.
    module HookFiles
      # Installs a hook script of the assets in .maf/coordination/harness-hooks/ of the project.
      def self.install(project, name)
        dest = File.join(project, ".maf", "coordination", "harness-hooks", name)
        copy(File.join(ASSETS, "harness-hooks", name), dest)
      end

      def self.copy(src, dest)
        FileUtils.mkdir_p(File.dirname(dest))
        return if File.exist?(dest) && File.read(dest) == File.read(src)

        FileUtils.install(src, dest, mode: 0o755)
        puts "  hook install: #{dest}"
      end
    end
  end
end
