# frozen_string_literal: true

module Maf
  class Vm
    # Template renders assets/lima/maf.yaml.erb for one project. The VM gets
    # the CLI of each harness of the project that has a vm_install command.
    class Template
      FILE = File.join(Flow::ROOT, "assets", "lima", "maf.yaml.erb")
      TASKWARRIOR = "3.5.0"
      TASKWARRIOR_URL = "https://github.com/GothenburgBitFactory/taskwarrior/releases/download/" \
                        "v%<version>s/task-%<version>s.tar.gz"

      def initialize(root, options)
        @root = root
        @options = options
      end

      def render = ERB.new(File.read(FILE), trim_mode: "-").result_with_hash(**values)

      # The steps that the user does after create.
      def notes
        manual = harnesses.reject(&:vm_install).map { |harness| "Install #{harness.name} in the VM yourself." }
        manual + ["Log in to each harness in the VM: maf vm shell, then start the harness once."]
      end

      private

      def values
        { project: @root, cpus: @options.cpus, memory: @options.memory, disk: @options.disk, gem: @options.gem,
          taskwarrior: TASKWARRIOR, taskwarrior_url: format(TASKWARRIOR_URL, version: TASKWARRIOR),
          harness_installs: harnesses.select(&:vm_install).to_h { |harness| [harness.name, harness.vm_install] } }
      end

      def harnesses = Maf.agents.map { |agent| agent["harness"] }.uniq.filter_map { |name| Shared::Harness[name] }
    end
  end
end
