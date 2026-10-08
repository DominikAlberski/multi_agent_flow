# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

require "json"

module Maf
  module Shared
    # GitIdentity is the git persona of the agents: the author and committer
    # of each commit that an agent or the flow makes. The key git_identity
    # ({"name", "email"}) of .maf/config.json sets it. Without that key, the
    # bot_user and bot_email of the github section count. Without both, git
    # uses its own config, as for a commit of the user.
    module GitIdentity
      KEYS = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL].freeze

      def self.pair(config)
        own = config["git_identity"] || {}
        bot = config.fetch("github", {})
        pair = own.empty? ? bot.values_at("bot_user", "bot_email") : own.values_at("name", "email")
        pair unless pair.any? { |value| value.to_s.empty? }
      end

      # The environment variables of git win over every git config file.
      def self.env(config)
        name, email = pair(config)
        name ? KEYS.zip([name, email, name, email]).to_h : {}
      end

      def self.apply(config) = ENV.update(env(config))

      def self.read(path)
        File.exist?(path) ? JSON.parse(File.read(path)) : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
