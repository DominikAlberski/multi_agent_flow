# frozen_string_literal: true

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

    def parser
      OptionParser.new do |o|
        o.banner = BANNER
        o.on("--roles LIST") { |v| @roles = v }
        o.on("--check") { @check = true }
        o.on("--install-deps") { @install_deps = true }
        o.on("--force") { @force = true }
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end
  end
end
