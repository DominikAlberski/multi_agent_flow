# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    module Sandbox
      # Paths holds the allowed write paths. The sandboxes compare real paths,
      # so /tmp becomes /private/tmp on macOS.
      class Paths
        COMMON = ["/tmp", "/var/tmp", "/private/var/folders", "~/.cache", "~/Library/Caches"].freeze

        def initialize(harness, dirs)
          @harness = harness
          @dirs = dirs
        end

        def dirs = real([*@dirs, ENV.fetch("TMPDIR", nil), *COMMON, *@harness.sandbox_dirs])
        def prefixes = real(@harness.sandbox_prefixes)
        def harness_dirs = real(@harness.sandbox_dirs)
        def existing = dirs.select { |dir| File.exist?(dir) }

        private

        def real(paths) = paths.compact.reject(&:empty?).map { |path| resolve(File.expand_path(path)) }.uniq

        def resolve(path)
          File.realpath(path)
        rescue SystemCallError
          File.exist?(File.dirname(path)) ? File.join(File.realpath(File.dirname(path)), File.basename(path)) : path
        end
      end
    end
  end
end
