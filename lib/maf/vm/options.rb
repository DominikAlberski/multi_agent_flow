# frozen_string_literal: true

module Maf
  class Vm
    # VmOptions holds the flags of maf vm create.
    VmOptions = Struct.new(:cpus, :memory, :disk, :gem, keyword_init: true) do
      # The VM sees only the project, so maf copies a local gem file into .maf/vm/.
      def self.parse(argv, root)
        options = new(cpus: 4, memory: 8, disk: 50, gem: "maf")
        parser(options).parse!(argv.dup)
        options.gem = copy_gem(options.gem, root) if options.gem.end_with?(".gem")
        options
      end

      def self.parser(options)
        OptionParser.new(USAGE) do |o|
          %i[cpus memory disk].each { |key| o.on("--#{key} N", Integer) { |value| options[key] = value } }
          o.on("--gem FILE") { |file| options.gem = file }
        end
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
