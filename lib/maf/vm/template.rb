# frozen_string_literal: true

module Maf
  class Vm
    # Template renders assets/lima/maf.yaml.erb for one project. The VM gets
    # the CLI of each harness that has a vm_install command.
    class Template
      FILE = File.join(Flow::ROOT, "assets", "lima", "maf.yaml.erb")
      TASKWARRIOR = "3.5.0"
      TASKWARRIOR_URL = "https://github.com/GothenburgBitFactory/taskwarrior/releases/download/" \
                        "v%<version>s/task-%<version>s.tar.gz"
      # The VM type and the mount type of Lima for each host OS.
      HOSTS = { "darwin" => { vm_type: "vz", mount_type: "virtiofs" },
                "linux" => { vm_type: "qemu", mount_type: "9p" } }.freeze

      def initialize(root, options, harnesses)
        @root = root
        @options = options
        @harnesses = harnesses
      end

      def render = ERB.new(File.read(FILE), trim_mode: "-").result_with_hash(**values)

      # The harnesses that the user installs in the VM.
      def notes = @harnesses.reject(&:vm_install).map { |harness| "Install #{harness.name} in the VM yourself." }

      private

      def values
        { project: @root, cpus: @options.cpus, memory: @options.memory, disk: @options.disk, gem: @options.gem,
          taskwarrior: TASKWARRIOR, taskwarrior_url: format(TASKWARRIOR_URL, version: TASKWARRIOR),
          harness_installs: @harnesses.select(&:vm_install).to_h { |harness| [harness.name, harness.vm_install] },
          **HOSTS.fetch(host) }
      end

      def host = RUBY_PLATFORM.include?("darwin") ? "darwin" : "linux"
    end
  end
end
