# frozen_string_literal: true

# role_limits.rb - save the session limits of a role in .maf/config.json.
#
#   maf worker restart frontend-developer_bot --max-context 80000
require "json"

module Maf
  # RoleLimits reads the limit flags of `maf worker start|restart` and saves
  # them under team.limits.<role> in .maf/config.json. The dispatcher reads
  # them when it starts, so a restart applies them. A flag of
  # `maf start --dispatch` still wins over a saved limit.
  class RoleLimits
    FLAGS = { "--max-context" => "max_context", "--max-session-runs" => "max_session_runs",
              "--cache-window" => "cache_window" }.freeze

    def self.parse(args) = FLAGS.filter_map { |flag, key| pair(args, flag, key) }.to_h
    def self.pair(args, flag, key) = (index = args.index(flag)) && [key, number(flag, args[index + 1])]

    def self.number(flag, text)
      value = Integer(text.to_s, exception: false)
      value && value >= 0 ? value : abort("maf: #{flag} needs a number of 0 or more")
    end

    def initialize(root) = @path = File.join(root, ".maf", "config.json")

    def save(role, limits)
      return if limits.empty?

      File.write(@path, JSON.pretty_generate(merged(manifest, role, limits)))
      puts "Saved limits of #{role}: #{limits.map { |key, value| "#{key}=#{value}" }.join(" ")}"
    end

    private

    def merged(data, role, limits)
      saved = data.dig("team", "limits").to_h
      team = data.fetch("team", {}).merge("limits" => saved.merge(role => saved[role].to_h.merge(limits)))
      data.merge("team" => team)
    end

    # A corrupt manifest must not be overwritten. Stop with a clear message instead.
    def manifest
      File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError
      abort "maf: #{@path} is not valid JSON. Fix it, then run this command again."
    end
  end
end
