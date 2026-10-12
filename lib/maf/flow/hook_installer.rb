# frozen_string_literal: true

module Maf
  module Flow
    # HookInstaller installs the harness hooks that pick up tasks when a
    # session ends. Each harness installs its own (Harness#install_hooks).
    # Some harnesses get theirs from bootstrap instead (Harness#bootstrap_dir).
    class HookInstaller
      def initialize(agents, project)
        names = agents.map { |a| a[:harness] }
        @harnesses = Harness.all.select { |harness| names.include?(harness.name) }
        @project = project
      end

      # Returns the result of each harness. A truthy result: the hook needs steps from the user.
      def install = @harnesses.map { |harness| harness.install_hooks(@project) }
    end
  end
end
