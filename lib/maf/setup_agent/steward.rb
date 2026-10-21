# frozen_string_literal: true

require "rbconfig"

module Maf
  module SetupAgent
    # Steward starts the steward daemon of the project. It runs before the
    # agent variables are set, so steward does not run as an agent.
    module Steward
      def self.ensure(root)
        script = File.join(root, ".maf", "bin", "steward")
        return if ENV["STEWARD_SKIP"] || !File.exist?(script)

        system(RbConfig.ruby, script, chdir: root, out: File::NULL, err: File::NULL)
      end
    end
  end
end
