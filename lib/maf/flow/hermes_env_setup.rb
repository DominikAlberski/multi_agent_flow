# frozen_string_literal: true

module Maf
  module Flow
    # HermesEnvSetup prints the step that lets Hermes give the flow variables to
    # the commands of an agent. The flow never edits the Hermes config.
    class HermesEnvSetup
      KEY = "terminal.client_env_passthrough"
      NAMES = %w[COORD_DIR COORD_ROLE COORD_WORKER COORD_DISPATCHED COORD_SLOT COORD_SESSION_PID TASKRC
                 MAF_BIN].freeze

      def initialize(config_yaml = File.join(Dir.home, ".hermes", "config.yaml"))
        @config_yaml = config_yaml
      end

      # Returns true when the user has a step left.
      def install
        names = listed
        return puts("  hermes env ready: #{KEY}") || false if (NAMES - names).empty?

        print_step(names) || true
      end

      def command(names) = "hermes config set #{KEY} '#{JSON.generate((names + NAMES).uniq)}'"

      def listed
        list = config.dig("terminal", "client_env_passthrough")
        list.is_a?(Array) ? list.map(&:to_s) : []
      end

      private

      def print_step(names)
        puts "", "  Hermes env: the commands of a Hermes agent get no COORD_* variables yet.",
             "  Do this step one time. It keeps the names that the list has now.", "", "    #{command(names)}", ""
      end

      def config
        data = YAML.safe_load_file(@config_yaml)
        data.is_a?(Hash) ? data : {}
      rescue SystemCallError, Psych::Exception
        {}
      end
    end
  end
end
