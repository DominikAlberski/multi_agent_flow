# frozen_string_literal: true

require "json"
require "shellwords"

module Maf
  class Vm
    # Template renders assets/lima/maf.yaml.erb for one project.
    class Template
      FILE = File.join(Flow::ROOT, "assets", "lima", "maf.yaml.erb")
      TASKWARRIOR = "3.5.0"
      # The VM checks the download. Change the checksum with the version.
      TASKWARRIOR_SHA256 = "9ea64b411f8314414f440ec765dfdf5a86c9f6159df47e2f60cff3db6b31157a"
      TASKWARRIOR_URL = "https://github.com/GothenburgBitFactory/taskwarrior/releases/download/" \
                        "v%<version>s/task-%<version>s.tar.gz"
      HOSTS = { "darwin" => { vm_type: "vz", mount_type: "virtiofs" },
                "linux" => { vm_type: "qemu", mount_type: "9p" } }.freeze

      def initialize(root, options, harnesses)
        @root = root
        @options = options
        @harnesses = harnesses
      end

      def render = ERB.new(File.read(FILE), trim_mode: "-").result_with_hash(**values)

      def notes = @harnesses.reject(&:vm_install).map { |harness| "Install #{harness.name} in the VM yourself." }

      private

      def values
        { project: @root, cpus: @options.cpus, memory: @options.memory, disk: @options.disk, gem_args: gem_args,
          taskwarrior: TASKWARRIOR, taskwarrior_url: format(TASKWARRIOR_URL, version: TASKWARRIOR),
          taskwarrior_sha256: TASKWARRIOR_SHA256,
          harness_installs: @harnesses.select(&:vm_install).to_h { |h| [h.name, [h.command, h.vm_install]] },
          **HOSTS.fetch(host) }
      end

      def gem_args = @options.gem == "maf" ? "maf -v #{Maf::VERSION.shellescape}" : @options.gem.shellescape

      def host = RUBY_PLATFORM.include?("darwin") ? "darwin" : "linux"
    end
  end
end
