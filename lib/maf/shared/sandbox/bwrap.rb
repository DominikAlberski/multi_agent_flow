# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "fileutils"

module Maf
  module Shared
    module Sandbox
      # Bwrap (Linux bubblewrap) mounts the whole file system read-only and
      # binds each allowed path read-write on top. Bubblewrap 0.10 and later
      # put a temporary overlay on the home folder: other writes there succeed,
      # but they are lost after the run. Some harnesses (Claude Code) write a
      # temporary file in the home folder, so they need the overlay.
      module Bwrap
        COMMAND = "bwrap"
        BASE = ["--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc", "/proc"].freeze

        def self.wrap(cmd, paths) = [COMMAND, *BASE, *home, *binds(paths), "--die-with-parent", "--", *cmd]

        def self.available?
          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, COMMAND)) }
        end

        def self.require! = available? || abort("maf: sandbox mode bwrap needs bubblewrap: apt install bubblewrap")

        def self.home = overlay? ? ["--overlay-src", Dir.home, "--tmp-overlay", Dir.home] : []
        def self.overlay? = IO.popen([COMMAND, "--help"], err: %i[child out], &:read).include?("--tmp-overlay")

        # A bind needs an existing path, so the folders of the harness are created first.
        def self.binds(paths)
          FileUtils.mkdir_p(paths.harness_dirs)
          paths.dirs.select { |dir| File.directory?(dir) }.flat_map { |dir| ["--bind", dir, dir] }
        end
      end
    end
  end
end
