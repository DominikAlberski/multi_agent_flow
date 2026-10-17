# frozen_string_literal: true

module Maf
  module Flow
    # Options parses the command line and holds the settings of one run.
    class Options
      attr_accessor :project, :agents, :role_efforts
      attr_reader :removed, :models, :efforts, :hermes_dir, :list_roles

      # Each flag: the OptionParser arguments, and a block that runs in the
      # Options instance with the flag value.
      FLAGS = [
        [["--project DIR"], ->(v) { @project = v }],
        [["--agent SPEC", "HARNESS:ROLE[:MODEL]"], ->(v) { @agents << parse_agent(v) }],
        [["--remove SPEC", "HARNESS:ROLE"], ->(v) { @removed << parse_agent(v) }],
        [["--model PAIR", "ROLE=MODEL"], ->(v) { @models.store(*v.split("=", 2)) }],
        [["--effort PAIR", "ROLE=LEVEL"], ->(v) { @efforts.store(*v.split("=", 2)) }],
        [["--hermes-dir DIR"], ->(v) { @hermes_dir = File.expand_path(v) }],
        [["--check"], ->(_) { @check = true }],
        [["--force"], ->(_) { @force = true }],
        [["--no-bootstrap"], ->(_) { @bootstrap = false }],
        [["--list-roles"], ->(_) { @list_roles = true }]
      ].freeze

      def initialize(argv)
        @argv, @agents, @removed, @models, @efforts = argv, [], [], {}, {}
        @role_efforts = {}
        @check = @force = @list_roles = false
        @bootstrap = true
      end

      def check? = @check
      def force? = @force
      def bootstrap? = @bootstrap

      # The settings that a harness reads for its role file folder.
      def settings = { "hermes_dir" => @hermes_dir }.compact

      def parse
        parser.parse!(@argv)
        self
      end

      # Flags that take a value. maf uses them to tell flag values from agent specs.
      def value_flags
        parser.top.list.grep(OptionParser::Switch::RequiredArgument).flat_map(&:long)
      end

      def model_for(agent)
        agent[:model] || @models[agent[:role]] || agent[:saved_model] || Harness[agent[:harness]]&.default_model
      end

      def effort_for(agent)
        @efforts[agent[:role]] || agent[:saved_effort] ||
          Models.default_effort(agent[:harness], @role_efforts[agent[:role]], model_for(agent))
      end

      private

      def parser
        OptionParser.new do |o|
          o.banner = "Usage: maf add|remove|update [HARNESS:ROLE ...] [options]"
          FLAGS.each { |args, set| o.on(*args) { |value| instance_exec(value, &set) } }
          o.on("-h", "--help") { puts o; exit 0 }
        end
      end

      def parse_agent(spec)
        harness, role, model = spec.split(":", 3)
        { harness: harness, role: role, model: model }
      end
    end
  end
end
