# frozen_string_literal: true

module Flow
  # Options parses the command line and holds the settings of one run.
  class Options
    attr_accessor :project, :agents
    attr_reader :removed, :models, :hermes_dir, :list_roles

    def initialize(argv)
      @argv = argv
      @agents = []
      @removed = []
      @models = {}
      @hermes_dir = DEFAULT_HERMES_DIR
      @check = @force = @list_roles = false
      @bootstrap = true
    end

    def check? = @check
    def force? = @force
    def bootstrap? = @bootstrap

    def parse
      parser.parse!(@argv)
      self
    end

    # Flags that take a value. maf uses them to tell flag values from agent specs.
    def value_flags
      parser.top.list.grep(OptionParser::Switch::RequiredArgument).flat_map(&:long)
    end

    def model_for(agent)
      agent[:model] || @models[agent[:role]] || agent[:saved_model] || DEFAULT_MODELS[agent[:harness]]
    end

    private

    def parser
      OptionParser.new do |o|
        o.banner = "Usage: maf add|remove|update [HARNESS:ROLE ...] [options]"
        o.on("--project DIR") { |v| @project = v }
        o.on("--agent SPEC", "HARNESS:ROLE[:MODEL]") { |v| @agents << parse_agent(v) }
        o.on("--remove SPEC", "HARNESS:ROLE") { |v| @removed << parse_agent(v) }
        o.on("--model PAIR", "ROLE=MODEL") { |v| k, m = v.split("=", 2); @models[k] = m }
        o.on("--hermes-dir DIR") { |v| @hermes_dir = File.expand_path(v) }
        o.on("--check") { @check = true }
        o.on("--force") { @force = true }
        o.on("--no-bootstrap") { @bootstrap = false }
        o.on("--list-roles") { @list_roles = true }
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end

    def parse_agent(spec)
      harness, role, model = spec.split(":", 3)
      { harness: harness, role: role, model: model }
    end
  end
end
