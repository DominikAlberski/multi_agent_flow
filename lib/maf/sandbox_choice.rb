# frozen_string_literal: true

module Maf
  # SandboxChoice asks for the sandbox of a new install. A later maf add keeps .maf/sandbox.json.
  class SandboxChoice
    CHOICES = [["Dispatched runs only (recommended)", %w[auto dispatch]],
               ["Dispatched runs and interactive sessions", %w[auto all]],
               ["Off", %w[off dispatch]]].freeze

    def initialize(prompt)
      @prompt = prompt
    end

    def args
      return [] if File.exist?(MANIFEST)

      mode, scope = ask.last
      ["--sandbox", mode, "--sandbox-scope", scope]
    end

    private

    def ask
      CHOICES.each_with_index { |(label, _), i| @prompt.say("  #{i + 1}) #{label}") }
      number = Integer(@prompt.ask("Sandbox (number, Enter = 1):").to_s, exception: false)
      number&.between?(1, CHOICES.size) ? CHOICES[number - 1] : CHOICES.first
    end
  end
end
