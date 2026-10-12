# frozen_string_literal: true

module Maf
  module Flow
    # Models finds the installed harnesses and the models that each one offers.
    # maf add shows them as choices and warns about a model name that the
    # harness does not know: a typo makes every dispatched run fail.
    # A list is nil when maf cannot read it. Then every name counts as known.
    module Models
      # Without any harness on PATH, maf shows all of them: the user may install one later.
      def self.installed
        found = Harness.all.select(&:installed?).map(&:name)
        found.empty? ? Harness.names : found
      end

      # A harness can read its list from a CLI, so each list is read once.
      def self.for(harness)
        @lists ||= {}
        @lists.key?(harness) ? @lists[harness] : @lists[harness] = Harness[harness]&.models
      end

      def self.known?(harness, model) = Harness[harness]&.known_model?(model, self.for(harness)) != false
      def self.default(harness) = Harness[harness]&.default_model
    end
  end
end
