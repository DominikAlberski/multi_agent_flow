# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    module Roles
      # Lead roles dispatch or coordinate instead of implementing. They own no
      # tasks: they get an inbox prompt and no task polling.
      LEADS = %w[project-manager architect].freeze

      # Hermes toolsets for a role with can_edit false: no file, code_execution,
      # or delegation toolset. The shell stays, because the role needs coord and git.
      READ_ONLY_TOOLSETS = "terminal,web,skills,todo,memory,session_search,clarify"
    end
  end
end
