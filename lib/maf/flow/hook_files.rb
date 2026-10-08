# frozen_string_literal: true

module Maf
  module Flow
    # HookFiles copies a hook script from the assets and makes it executable.
    module HookFiles
      def self.copy(src, dest)
        FileUtils.mkdir_p(File.dirname(dest))
        return if File.exist?(dest) && File.read(dest) == File.read(src)

        FileUtils.install(src, dest, mode: 0o755)
        puts "  hook install: #{dest}"
      end
    end
  end
end
