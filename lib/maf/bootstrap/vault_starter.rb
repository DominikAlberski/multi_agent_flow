# frozen_string_literal: true

module Maf
  module Bootstrap
    # VaultStarter starts the vault watcher once the script is in place, so
    # shared memory is live right after install with no extra step for the
    # common case (graphify already installed). It skips the start when
    # graphify is missing. The printed next steps cover that case.
    class VaultStarter
      def initialize(project)
        @project = project
      end

      # Returns the note that the next steps print.
      def start(actions)
        return "skipped (VAULT_SKIP is set)" if ENV["VAULT_SKIP"]
        return "run `vault` after bootstrap (graphify is needed only to run it)" unless installed?(actions)
        return "run `vault` once graphify is installed" unless Bootstrap.which("graphify")

        launch
      end

      private

      def script
        @project.bin_path("vault")
      end

      def installed?(actions)
        actions.any? { |act| act[:path] == script && act[:kind] != :refuse }
      end

      def launch
        ok = system(script, chdir: @project.target)
        note = ok ? "started (`vault status` / `vault stop`)" : "failed to start; see .maf/coordination/vault.log"
        Bootstrap.say("vault: #{note}")
        note
      end
    end
  end
end
