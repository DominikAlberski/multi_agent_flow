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
require "erb"
require "fileutils"
require "optparse"
require "tempfile"
require_relative "flow"
require_relative "shared/harness"

module Maf
  # Vm runs limactl for the VM of the project.
  class Vm
    USAGE = "usage: maf vm create [--cpus N] [--memory GIB] [--disk GIB] [--gem FILE] [--[no-]copy-logins]" \
            "|login|start|stop|delete|status|shell [COMMAND ...]"
    LIMACTL = "limactl"
    INSTALL = "brew install lima (macOS), or Lima and QEMU from https://lima-vm.io/docs/installation/ (Linux)"

    def initialize(argv, root)
      @action, *@args = argv
      @root = root
    end

    def run
      abort "maf: maf vm needs Lima. Install it: #{INSTALL}" unless Shared::Harness.on_path?(LIMACTL)

      action = { "create" => :create, "login" => :login, "shell" => :shell, "status" => :status }[@action]
      action ? send(action) : lifecycle
    end

    def name = "maf-#{File.basename(@root).downcase.gsub(/[^a-z0-9-]/, "-")}"

    private

    def lifecycle
      abort USAGE unless %w[start stop delete].include?(@action)

      limactl(@action, *("--force" if @action == "delete"), name)
    end

    def create
      options = VmOptions.parse(@args, @root)
      template = Template.new(@root, options, harnesses)
      Tempfile.create(["maf-vm", ".yaml"]) { |file| create_from(file.path, template.render) }
      template.notes.each { |note| puts note }
      Login.new(name, harnesses, options.login).run
    end

    # Copy the logins again, for example after a harness was added.
    def login = Login.new(name, harnesses, VmOptions.parse(@args, @root).login).run
    def harnesses = Maf.agents.map { |agent| agent["harness"] }.uniq.filter_map { |id| Shared::Harness[id] }

    def create_from(path, yaml)
      File.write(path, yaml)
      limactl("create", "--tty=false", "--name=#{name}", path) && limactl("start", name)
    end

    def shell = Kernel.exec(LIMACTL, "shell", "--workdir", @root, name, *@args)
    def status = limactl("list", name)
    def limactl(*args) = system(LIMACTL, *args) || abort("maf: #{LIMACTL} #{args.first} failed.")
  end
end

require_relative "vm/options"
require_relative "vm/template"
require_relative "vm/login"
