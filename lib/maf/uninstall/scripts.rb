# frozen_string_literal: true

module Uninstall
  class Scripts
    SIGNATURES = { "coord" => Bootstrap::COORD_SIGNATURE, "setup_agent" => Bootstrap::SETUP_AGENT_SIGNATURE,
                   "dispatcher" => Bootstrap::DISPATCHER_SIGNATURE, "dashboard" => Bootstrap::DASHBOARD_SIGNATURE,
                   "vault" => Bootstrap::VAULT_SIGNATURE, "vault-daemon" => Bootstrap::VAULT_SIGNATURE,
                   Bootstrap::OPENCODE_PLUGIN => Bootstrap::OPENCODE_BOARD_WATCH_SIGNATURE }.freeze

    def initialize(project) = @project = project

    def steps
      SIGNATURES.map { |name, signature| [File.join(@project, name), signature] }
                .select { |path, signature| Owned.signed?(path, signature) }
                .map { |path, _| Owned.remove(path) }
    end
  end
end
