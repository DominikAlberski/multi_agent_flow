# frozen_string_literal: true

require "open3"

module Maf
  module Flow
    # Models finds the installed harnesses and the models that each one offers.
    # maf add shows them as choices and warns about a model name that the
    # harness does not know: a typo makes every dispatched run fail.
    # A list is nil when maf cannot read it. Then every name counts as known.
    module Models
      # Claude Code has no command that lists models. The aliases follow the
      # newest model of each family. A full ID is claude-<family>-<version>.
      CLAUDE = %w[claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-1 opus sonnet haiku fable].freeze
      CLAUDE_NAME = /\A(?:(?:opus|sonnet|haiku|fable)(?:\[1m\])?|opusplan|default|best|
                       (?:[\w.-]+\.)?(?:anthropic\.)?claude-(?:opus|sonnet|haiku|fable)-\d[\w.:@\[\]-]*)\z/x
      CODEX_CACHE = File.join(Dir.home, ".codex", "models_cache.json")

      # Without any harness on PATH, maf shows all of them: the user may install one later.
      def self.installed
        found = HARNESSES.select { |harness| on_path?(harness) }
        found.empty? ? HARNESSES : found
      end

      def self.on_path?(command)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, command)) }
      end

      def self.for(harness)
        @lists ||= {}
        return @lists[harness] if @lists.key?(harness)

        @lists[harness] = { "claude" => -> { CLAUDE }, "codex" => -> { codex }, "opencode" => -> { opencode } }
                          .fetch(harness, -> {}).call
      end

      def self.known?(harness, model)
        return model.match?(CLAUDE_NAME) if harness == "claude"

        self.for(harness).nil? || self.for(harness).include?(model)
      end

      # Codex keeps the model list of the account in a cache file. Hidden models are internal.
      def self.codex
        models = JSON.parse(File.read(CODEX_CACHE)).fetch("models")
        models.select { |m| m["visibility"] == "list" }.map { |m| m["slug"] }
      rescue SystemCallError, JSON::ParserError, KeyError, NoMethodError
        nil
      end

      def self.opencode
        return nil unless on_path?("opencode")

        out, status = Open3.capture2("opencode", "models", err: File::NULL)
        status.success? && !out.strip.empty? ? out.split : nil
      rescue SystemCallError
        nil
      end
    end
  end
end
