# frozen_string_literal: true

module Maf
  module Flow
    # HermesHook reports the state of the hook that picks up tasks when a Hermes
    # session ends. Hermes keeps hooks in the global config.yaml and asks for a
    # one-time consent, so the flow prints commands instead of editing the file.
    # Every method takes a path, so a test can use fixtures.
    module HermesHook
      EVENT = "on_session_end"
      SCRIPT_NAME = "next-task.sh"
      TIMEOUT = 30
      # Hermes rounds the recorded approval time to microseconds, so compare with
      # a small tolerance. A rewritten hook moves the mtime far past it.
      MTIME_TOLERANCE = 2

      def self.declared?(config_yaml, script_path)
        return false unless File.exist?(config_yaml)

        content = File.read(config_yaml)
        content.include?(script_path) || content.include?(SCRIPT_NAME)
      end

      def self.approved?(allowlist, script_path, mtime)
        entry = approvals(allowlist).find { |item| item["command"] == script_path && item["event"] == EVENT }
        entry ? (mtime - Time.iso8601(entry["script_mtime_at_approval"].to_s)).abs <= MTIME_TOLERANCE : false
      rescue ArgumentError, TypeError
        false
      end

      def self.approvals(allowlist)
        return [] unless File.exist?(allowlist)

        JSON.parse(File.read(allowlist)).fetch("approvals", [])
      rescue JSON::ParserError
        []
      end

      def self.config_command(script_path)
        %(hermes config set hooks.#{EVENT} '[{"command":"#{script_path}","timeout":#{TIMEOUT}}]')
      end

      def self.approve_command = "hermes chat --oneshot --accept-hooks -q ok"

      def self.check_command = "hermes hooks doctor"
    end
  end
end
