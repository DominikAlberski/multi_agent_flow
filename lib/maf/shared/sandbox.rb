# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "project"

module Maf
  module Shared
    # Sandbox runs an agent command in an OS sandbox. The mode comes from
    # MAF_SANDBOX or from "sandbox": {"mode": ...} in .maf/config.json.
    # off: no sandbox. seatbelt: macOS sandbox-exec. The agent can read all
    # files, but it can write only to the project and to the paths of its harness.
    module Sandbox
      MODES = %w[off seatbelt].freeze

      def self.mode(manifest = Project.manifest)
        mode = ENV.fetch("MAF_SANDBOX", nil).to_s
        mode = manifest.dig("sandbox", "mode") || "off" if mode.empty?
        abort "maf: unknown sandbox mode '#{mode}' (use #{MODES.join(", ")})" unless MODES.include?(mode)
        Seatbelt.require! if mode == "seatbelt"
        mode
      end

      # The command unchanged when the mode is off. coord_dir: the board, if COORD_DIR moved it.
      def self.wrap(cmd, harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        manifest = Project.manifest
        return cmd if mode(manifest) == "off"

        Seatbelt.wrap(harness.sandboxed(cmd), paths(harness, manifest, coord_dir))
      end

      def self.describe(harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        manifest = Project.manifest
        mode(manifest) == "off" ? "off" : "seatbelt, writes to #{paths(harness, manifest, coord_dir).dirs.join(", ")}"
      end

      # The project, the board, and the "write" list of the config.
      def self.paths(harness, manifest, coord_dir)
        Seatbelt::Paths.new(harness, [Project.root, coord_dir, *Array(manifest.dig("sandbox", "write"))])
      end

      # Seatbelt writes a sandbox profile that denies each file write outside the allowed paths.
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

        # Paths holds the allowed write paths. Seatbelt compares real paths, so /tmp becomes /private/tmp.
        class Paths
          COMMON = ["/tmp", "/private/var/folders", "~/.cache", "~/Library/Caches"].freeze

          def initialize(harness, dirs)
            @harness = harness
            @dirs = dirs
          end

          def dirs = real([*@dirs, ENV.fetch("TMPDIR", nil), *COMMON, *@harness.sandbox_dirs])
          def prefixes = real(@harness.sandbox_prefixes)

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
end
