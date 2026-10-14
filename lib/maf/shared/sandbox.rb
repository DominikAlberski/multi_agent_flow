# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "json"
require_relative "project"
require_relative "harness"
require_relative "sandbox/paths"
require_relative "sandbox/seatbelt"
require_relative "sandbox/bwrap"
require_relative "sandbox/links"

module Maf
  module Shared
    # Sandbox runs an agent command in the OS sandbox of the mode in .maf/sandbox.json.
    module Sandbox
      BACKENDS = { "seatbelt" => Seatbelt, "bwrap" => Bwrap }.freeze
      MODES = ["off", "auto", *BACKENDS.keys].freeze
      POLICY = File.join(".maf", "sandbox.json")

      def self.policy
        path = File.join(Project.root, POLICY)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path)).tap { |data| data.is_a?(Hash) || abort("maf: #{POLICY} must hold a JSON object.") }
      rescue SystemCallError, JSON::ParserError => e
        abort "maf: cannot read #{POLICY}: #{e.message.lines.first.strip}. Fix the file, or delete it."
      end

      def self.mode(policy = self.policy)
        mode = ENV.fetch("MAF_SANDBOX", nil).to_s
        mode = policy["mode"] || "off" if mode.empty?
        abort "maf: unknown sandbox mode '#{mode}' (use #{MODES.join(", ")})" unless MODES.include?(mode)
        (mode == "auto" ? native : mode).tap { |name| BACKENDS[name]&.require! }
      end

      def self.native = RUBY_PLATFORM.include?("darwin") ? "seatbelt" : "bwrap"

      def self.wrap(cmd, harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        policy = self.policy
        mode = mode(policy)
        mode == "off" ? cmd : BACKENDS[mode].wrap(harness.sandboxed(cmd), paths(harness, policy, coord_dir))
      end

      def self.keeping_links(harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        links = protected_links(harness, coord_dir)
        yield
      ensure
        Links.restore(links || {})
      end

      def self.protected_links(harness, coord_dir)
        policy = self.policy
        mode(policy) == "bwrap" && !Bwrap.inside? ? Links.record(paths(harness, policy, coord_dir).protected) : {}
      end

      def self.describe(harness, coord_dir: ENV.fetch("COORD_DIR", nil))
        policy = self.policy
        mode = mode(policy)
        mode == "off" ? "off" : "#{mode}, #{writes(paths(harness, policy, coord_dir))}"
      end

      def self.writes(paths)
        state = paths.harness_dirs.select { |dir| File.exist?(dir) }
        "writes to #{paths.existing.join(", ")}#{", and the state files in #{state.join(", ")}" if state.any?}"
      end

      def self.paths(harness, policy, coord_dir)
        protect_policy
        Paths.new([harness, *project_harnesses].uniq, Project.root, coord_dir, Array(policy["write"]))
      end

      def self.project_harnesses = Project.manifest.fetch("agents", []).filter_map { |a| Harness[a["harness"]] }

      def self.protect_policy
        path = File.join(Project.root, POLICY)
        File.write(path, "{}\n") unless File.exist?(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
