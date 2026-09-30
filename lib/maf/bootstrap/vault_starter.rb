# frozen_string_literal: true

module Bootstrap
  # VaultStarter starts the vault watcher once the script is in place, so
  # shared memory is live right after install with no extra step for the
  # common case (graphify already installed). It skips the start when
  # graphify is missing. The printed next steps cover that case.
  class VaultStarter
    def initialize(project)
      @project = project
      @script = project.vault_script
    end

    # Returns the note that the next steps print.
    def start(actions)
      return "skipped (VAULT_SKIP is set)" if ENV["VAULT_SKIP"]
      return "run `./#{@script}` after bootstrap (graphify not needed at install time, only to run it)" unless installed?(actions)
      return "run `./#{@script}` once graphify is installed" unless Bootstrap.which("graphify")

      launch
    end

    private

    def installed?(actions)
      actions.any? { |act| act[:path] == @project.path(@script) && act[:kind] != :refuse }
    end

    def launch
      ok = system(@project.path(@script), chdir: @project.target)
      cmd = "./#{@script}"
      note = ok ? "started (`#{cmd} status` / `#{cmd} stop`)" : "failed to start; see coordination/vault.log"
      Bootstrap.say("vault: #{note}")
      note
    end
  end
end
