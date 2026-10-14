# frozen_string_literal: true

module Maf
  class Vm
    VmOptions = Struct.new(:cpus, :memory, :disk, :gem, :login, keyword_init: true) do
      def self.parse(argv, root)
        options = new(cpus: 4, memory: 4, disk: 20, gem: "maf", login: $stdin.tty? ? :ask : :none)
        parse!(options, argv)
        options.gem = copy_gem(options.gem, root) if options.gem.end_with?(".gem")
        options
      end

      def self.parse!(options, argv)
        parser(options).parse!(argv.dup)
      rescue OptionParser::ParseError => e
        abort "maf: #{e.message}\n#{USAGE}"
      end

      def self.parser(options)
        OptionParser.new(USAGE) do |o|
          %i[cpus memory disk].each { |key| o.on("--#{key} N", Integer) { |value| options[key] = positive(value) } }
          o.on("--gem FILE") { |file| options.gem = file }
          o.on("--[no-]copy-logins") { |copy| options.login = copy ? :all : :none }
        end
      end

      def self.positive(value)
        value.positive? ? value : raise(OptionParser::InvalidArgument, "#{value} (use a number above 0)")
      end

      def self.copy_gem(file, root)
        abort "maf: #{file} missing." unless File.exist?(file)

        dest = File.join(root, ".maf", "vm", File.basename(file))
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(file, dest)
        dest
      end
    end
  end
end
