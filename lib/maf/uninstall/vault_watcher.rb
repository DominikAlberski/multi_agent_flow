# frozen_string_literal: true

module Uninstall
  # The vault watcher runs detached. Stop it while its script still exists.
  class VaultWatcher
    def initialize(project) = @project = project

    def steps
      return [] unless File.exist?(File.join(@project, "coordination", "vault.pid")) && script

      [Step.new("stop vault watcher", -> { system(script, "stop", chdir: @project) })]
    end

    def script
      %w[vault vault-daemon].map { |name| File.join(@project, name) }
                            .find { |path| Owned.signed?(path, Bootstrap::VAULT_SIGNATURE) }
    end
  end
end
