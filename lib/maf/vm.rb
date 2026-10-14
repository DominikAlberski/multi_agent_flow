# frozen_string_literal: true

# vm.rb - run the whole team in a Lima VM (https://lima-vm.io).
#
#   maf vm create [--cpus N] [--memory GIB] [--disk GIB] [--gem FILE] [--[no-]copy-logins]
#   maf vm login [--copy-logins]
#   maf vm start | stop | delete | status
#   maf vm shell [COMMAND ...]
#
# The VM mounts only the project folder, at the same path as on the host.
# The host is macOS (Apple Virtualization) or Linux (QEMU with KVM).
# Run maf, coord, and each agent in the VM. Read and review the work on the host.
require "digest"
require "erb"
require "fileutils"
require "json"
require "optparse"
require "tempfile"
require_relative "flow"
require_relative "shared/harness"

module Maf
  # Vm runs limactl for the VM of the project.
  class Vm
    USAGE = "usage: maf vm create [--cpus N] [--memory GIB] [--disk GIB] [--gem FILE] [--[no-]copy-logins]" \
            "|login|start|stop|delete|status|shell [COMMAND ...]"
    ACTIONS = %w[create login start stop delete status shell].freeze
    LIMACTL = "limactl"
    INSTALL = "brew install lima (macOS), or Lima and QEMU from https://lima-vm.io/docs/installation/ (Linux)"

    def initialize(argv, root)
      @action, *@args = argv
      @root = File.realpath(root)
    end

    def run
      abort USAGE unless ACTIONS.include?(@action)
      abort "maf: maf vm needs Lima. Install it: #{INSTALL}" unless Shared::Harness.on_path?(LIMACTL)

      owned! unless @action == "create"
      %w[start stop delete].include?(@action) ? lifecycle : send(@action)
    end

    def name = "maf-#{slug}-#{Digest::SHA256.hexdigest(@root)[0, 8]}"
    def slug = File.basename(@root).downcase.gsub(/[^a-z0-9-]/, "-")[0, 30]

    ENV_SCRIPT = '[ -f .maf/env.sh ] && . ./.maf/env.sh; export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"; ' \
                 '[ $# -gt 0 ] || set -- bash -l; exec "$@"'

    def shell_command = [LIMACTL, "shell", "--workdir", @root, name, "bash", "-c", ENV_SCRIPT, "bash", *@args]

    private

    def owned!
      mounts = IO.popen([LIMACTL, "list", "--format", "{{json .Config.Mounts}}", name], err: File::NULL, &:read)
      abort "maf: no VM for this project. Run: maf vm create" if mounts.strip.empty?
      return if Array(JSON.parse(mounts)).any? { |mount| mount["location"] == @root }

      abort "maf: the VM #{name} does not mount #{@root}. maf does not touch it."
    end

    def lifecycle
      limactl(@action, *("--force" if @action == "delete"), name)
    end

    def create
      options = VmOptions.parse(@args, @root)
      template = Template.new(@root, options, harnesses)
      Tempfile.create(["maf-vm", ".yaml"]) { |file| create_from(file.path, template.render) }
      template.notes.each { |note| puts note }
      Login.new(name, harnesses, options.login).run
    end

    def login = Login.new(name, harnesses, VmOptions.parse(@args, @root).login).run

    def harnesses
      ids = Shared::Project.manifest.fetch("agents", []).map { |agent| agent["harness"] }
      ids.uniq.filter_map { |id| Shared::Harness[id] }
    end

    def create_from(path, yaml)
      File.write(path, yaml)
      limactl("create", "--tty=false", "--name=#{name}", path) && limactl("start", name)
    end

    def shell = Kernel.exec(*shell_command)
    def status = limactl("list", name)
    def limactl(*args) = system(LIMACTL, *args) || abort("maf: #{LIMACTL} #{args.first} failed.")
  end
end

require_relative "vm/options"
require_relative "vm/template"
require_relative "vm/login"
