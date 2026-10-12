# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "erb"
require "json"
require_relative "defaults"
require_relative "output"

module Maf
  module Shared
    # Harness is the registry of the agent harnesses. Each file in harnesses/
    # defines one harness: a subclass of Base. The rest of maf asks the
    # registry and never names a harness.
    module Harness
      def self.register(klass) = (@classes ||= []) << klass
      def self.all = @all ||= @classes.map(&:new).sort_by(&:name)
      def self.names = all.map(&:name)
      def self.[](name) = all.find { |harness| harness.name == name }
      def self.fetch(name) = self[name] || raise(KeyError, "unknown harness '#{name}' (use #{names.join(", ")})")
      def self.known?(name) = !self[name].nil?

      def self.on_path?(command)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, command)) }
      end

      # Base is the interface of a harness. A harness file overrides the
      # methods that its CLI needs. Every other method keeps the default here.
      # The methods are grouped by the part of maf that calls them.
      class Base
        def self.inherited(klass)
          super
          Harness.register(klass)
        end

        # The harness name in `maf add HARNESS:ROLE`. It comes from the class name.
        def name = self.class.name.split("::").last.downcase
        def to_s = name

        # The CLI of the harness. `maf add` offers only the installed harnesses.
        def command = name
        def installed? = Harness.on_path?(command)

        include RoleFiles
        include Setup
        include Run

        # The tool calls of one session, for the analyst: [[name, command, size], ...].
        def transcript_calls(_session_id) = []

        # The JSON objects of a transcript file, one per line. A broken line is skipped.
        def jsonl(path) = path ? File.foreach(path).filter_map { |line| Events.parse(line.strip) } : []
      end
    end
  end
end
