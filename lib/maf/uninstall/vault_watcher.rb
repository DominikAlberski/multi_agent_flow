# frozen_string_literal: true

module Maf
  module Uninstall
    # The vault watcher runs detached. Stop it while its script still exists.
    class VaultWatcher
      def initialize(project) = @project = project

      def steps
        return [] unless File.exist?(File.join(@project, ".maf", "coordination", "vault.pid")) && script

        [Step.new("stop vault watcher", -> { system(script, "stop", chdir: @project) })]
      end

      def script
        path = File.join(@project, ".maf", "bin", "vault")
        path if Owned.signed?(path, Bootstrap::VAULT_SIGNATURE)
      end
    end
  end
end
