# frozen_string_literal: true

module Maf
  module Bootstrap
    # Options parses the bootstrap command line.
    class Options
      DEFAULT_ROLES = "architect,backend-developer,frontend-developer,reviewer,tester"
      BANNER = "Usage: bootstrap.rb /path/to/project [--roles a,b,c] [--check] [--install-deps] [--force]"

      attr_reader :target, :roles, :check, :install_deps, :force

      def initialize(argv)
        @roles = DEFAULT_ROLES
        @check = @install_deps = @force = false
        parser.parse!(argv)
        @target = argv.first
      end

      private

      # Each flag and the block that runs in the Options instance with its value.
      FLAGS = { "--roles LIST" => ->(v) { @roles = v }, "--check" => ->(_) { @check = true },
                "--install-deps" => ->(_) { @install_deps = true }, "--force" => ->(_) { @force = true } }.freeze

      def parser
        OptionParser.new do |o|
          o.banner = BANNER
          FLAGS.each { |flag, set| o.on(flag) { |value| instance_exec(value, &set) } }
          o.on("-h", "--help") { puts o; exit 0 }
        end
      end
    end
  end
end
