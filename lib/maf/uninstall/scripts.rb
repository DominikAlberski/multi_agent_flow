# frozen_string_literal: true

module Uninstall
  class Scripts
    SIGNATURES = { ".maf/bin/coord" => Bootstrap::COORD_SIGNATURE,
                   ".maf/bin/dispatcher" => Bootstrap::DISPATCHER_SIGNATURE,
                   ".maf/bin/dashboard" => Bootstrap::DASHBOARD_SIGNATURE,
                   ".maf/bin/vault" => Bootstrap::VAULT_SIGNATURE,
                   ".maf/bin/doc-graph-refresh" => Bootstrap::DOC_GRAPH_SIGNATURE,
                   ".maf/env.sh" => Bootstrap::ENV_SIGNATURE,
                   Bootstrap::OPENCODE_PLUGIN => Bootstrap::OPENCODE_BOARD_WATCH_SIGNATURE }.freeze

    def initialize(project) = @project = project

    def steps
      SIGNATURES.map { |name, signature| [File.join(@project, name), signature] }
                .select { |path, signature| Owned.signed?(path, signature) }
                .map { |path, _| Owned.remove(path) }
    end
  end
end
