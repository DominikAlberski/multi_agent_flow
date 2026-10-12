# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "json"

module Maf
  module Shared
    module Harness
      # Events reads the JSON event lines of a harness run. Each harness takes
      # its session ID from one specific event, never from free text, so a
      # prompt or a handoff note that the agent echoes cannot supply a false ID.
      module Events
        def self.all(output) = output.lines.filter_map { |line| parse(line.strip) }

        def self.last(output, &match) = all(output).reverse.find(&match) || {}

        def self.parse(line)
          event = line.start_with?("{") ? JSON.parse(line) : nil
          event.is_a?(Hash) ? event : nil
        rescue JSON::ParserError
          nil
        end
      end

      # Usage turns the token usage of a harness into one shape.
      #
      # input_tokens counts every input token, cache reads included.
      # cached_input_tokens counts the cache reads, which cost a fraction of the
      # input price. cache_write_input_tokens counts the cache writes, which cost
      # more than the input price. Claude Code reports cache reads and cache
      # writes outside its input_tokens, so they are added. Codex reports them inside.
      module Usage
        def self.normalize(data)
          return nil unless data.is_a?(Hash)

          { "input_tokens" => input(data),
            "cached_input_tokens" => int(data, "cached_input_tokens", "cache_read_input_tokens"),
            "cache_write_input_tokens" => int(data, "cache_write_input_tokens", "cache_creation_input_tokens"),
            "output_tokens" => int(data, "output_tokens", "completion_tokens") }
        end

        def self.input(data)
          int(data, "input_tokens", "prompt_tokens") + int(data, "cache_read_input_tokens") +
            int(data, "cache_creation_input_tokens")
        end

        def self.int(data, *names) = data.values_at(*names).compact.first.to_i

        def self.sum(list) = list.empty? ? nil : list.reduce { |total, usage| total.merge(usage) { |_, a, b| a + b } }
      end
    end
  end
end
