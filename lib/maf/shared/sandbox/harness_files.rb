# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    module Sandbox
      # HarnessFiles holds the state paths and the protected paths in the folders of the harnesses.
      class HarnessFiles
        def initialize(harnesses, real)
          @harnesses = harnesses
          @real = real
        end

        def dirs = @dirs ||= @real.call(@harnesses.flat_map(&:sandbox_dirs))
        def prefixes = @real.call(@harnesses.flat_map(&:sandbox_prefixes))
        def placeholders = @harnesses.flat_map(&:sandbox_placeholders)
        def config = @harnesses.flat_map(&:sandbox_protected).select { |path| File.file?(path) }

        def state
          @state ||= @harnesses.flat_map(&:sandbox_state).map do |pattern|
            pattern = File.expand_path(pattern)
            File.join(@real.call([File.dirname(pattern)]).first, File.basename(pattern))
          end
        end

        def state?(path)
          dir = dirs.find { |folder| path.start_with?("#{folder}/") } or return false
          top = File.join(dir, path.delete_prefix("#{dir}/").split("/").first)
          state.any? { |pattern| File.fnmatch?(pattern, top, File::FNM_DOTMATCH | File::FNM_PATHNAME) }
        end

        def locked
          @locked ||= (dirs.flat_map { |dir| children(dir) }.reject { |path| state?(path) } +
                       @harnesses.flat_map(&:sandbox_protected)).uniq
        end

        private

        def children(dir)
          Dir.children(dir).map { |name| File.join(dir, name) }
        rescue SystemCallError
          []
        end
      end
    end
  end
end
