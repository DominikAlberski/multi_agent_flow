# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "fileutils"

module Maf
  module Shared
    module Sandbox
      # Links puts back a protected symlink that the agent changed in a bwrap run.
      module Links
        def self.record(paths) = paths.select { |path| File.symlink?(path) }.to_h { |path| [path, File.readlink(path)] }

        def self.restore(links) = links.each { |link, target| restore_link(link, target) }

        def self.restore_link(link, target)
          return if File.symlink?(link) && File.readlink(link) == target

          warn "maf: sandbox: the agent changed the protected link #{link}. maf put it back."
          FileUtils.rm_rf(link) && File.symlink(target, link)
        rescue SystemCallError => e
          warn "maf: sandbox: cannot put back the link #{link}: #{e.message}"
        end
      end
    end
  end
end
