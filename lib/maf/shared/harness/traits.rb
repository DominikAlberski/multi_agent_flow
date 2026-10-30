# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "base"

module Maf
  module Shared
    module Harness
      # ResultEvent reads a run that ends with one JSON result event: the
      # session ID, the result text, and the usage.
      module ResultEvent
        def result_event(output) = Events.last(output) { |event| result_event?(event) }
        def result_event?(event) = event["type"] == "result"
        def final_event?(event) = result_event?(event)
        def result_text(output) = result_event(output)["result"]
        def session_id(output) = present(result_event(output)["session_id"])
        def usage(output) = Usage.normalize(result_event(output)["usage"])
      end

      # PrependsRole is for a CLI without an agent flag. A fresh session gets
      # the role file text in front of the prompt. A resumed session has it.
      module PrependsRole
        FRONT_MATTER = /\A---\n.*?\n---\n+/m

        def first_prompt(role, prompt, session_id) = session_id ? prompt : role_text(role) + prompt

        def role_text(role)
          path = role_path(role)
          path && File.exist?(path) ? "#{File.read(path).sub(FRONT_MATTER, "")}\n\n" : ""
        end
      end
    end
  end
end
