# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "project"
require_relative "sandbox/paths"
require_relative "sandbox/seatbelt"
require_relative "sandbox/bwrap"

module Maf
  module Shared
    # Sandbox runs an agent command in an OS sandbox. The mode comes from
    # MAF_SANDBOX or from "sandbox": {"mode": ...} in .maf/config.json.
    # off: no sandbox. seatbelt: macOS sandbox-exec. bwrap: Linux bubblewrap.
    # auto: seatbelt on macOS, bwrap on Linux. The agent can read all files,
    # but it can write only to the project and to the paths of its harness.
    module Sandbox
      BACKENDS = { "seatbelt" => Seatbelt, "bwrap" => Bwrap }.freeze
      MODES = ["off", "auto", *BACKENDS.keys].freeze

      def self.mode(manifest = Project.manifest)
        mode = ENV.fetch("MAF_SANDBOX", nil).to_s
        mode = manifest.dig("sandbox", "mode") || "off" if mode.empty?
        abort "maf: unknown sandbox mode '#{mode}' (use #{MODES.join(", ")})" unless MODES.include?(mode)
        (mode == "auto" ? native : mode).tap { |name| BACKENDS[name]&.require! }
      end

      def self.native = RUBY_PLATFORM.include?("darwin") ? "seatbelt" : "bwrap"

      # The command unchanged when the mode is off. coord_dir: the board, if COORD_DIR moved it.
      def self.wrap(cmd, harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        manifest = Project.manifest
        mode = mode(manifest)
        mode == "off" ? cmd : BACKENDS[mode].wrap(harness.sandboxed(cmd), paths(harness, manifest, coord_dir))
      end

      def self.describe(harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        manifest = Project.manifest
        mode = mode(manifest)
        mode == "off" ? "off" : "#{mode}, writes to #{paths(harness, manifest, coord_dir).existing.join(", ")}"
      end

      # The project, the board, and the "write" list of the config.
      def self.paths(harness, manifest, coord_dir)
        Paths.new(harness, [Project.root, coord_dir, *Array(manifest.dig("sandbox", "write"))])
      end
    end
  end
end
