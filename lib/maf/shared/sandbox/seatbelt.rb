# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    module Sandbox
      # Seatbelt (macOS) writes a sandbox profile that denies each file write outside the allowed paths.
      module Seatbelt
        COMMAND = "sandbox-exec"
        DEVICES = '(literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper") ' \
                  '(regex #"^/dev/tty") (regex #"^/dev/fd/") (regex #"^/dev/ptmx")'

        def self.wrap(cmd, paths) = [COMMAND, "-p", profile(paths), *cmd]

        def self.available? = File.executable?("/usr/bin/#{COMMAND}")
        def self.require! = available? || abort("maf: sandbox mode seatbelt needs #{COMMAND} (macOS only).")

        def self.profile(paths)
          rules = paths.dirs.map { |dir| "(subpath #{quote(dir)})" } +
                  paths.prefixes.map { |prefix| "(prefix #{quote(prefix)})" }
          "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* #{DEVICES}\n  #{rules.join("\n  ")})\n"
        end

        def self.quote(path) = "\"#{path.gsub(/["\\]/) { |char| "\\#{char}" }}\""
      end
    end
  end
end
