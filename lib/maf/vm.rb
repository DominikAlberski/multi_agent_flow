# frozen_string_literal: true

# vm.rb - run the whole team in a Lima VM (https://lima-vm.io).
#
#   maf vm create [--cpus N] [--memory GIB] [--disk GIB] [--gem FILE]
#   maf vm start | stop | delete | status
#   maf vm shell [COMMAND ...]
#
# The VM mounts only the project folder, at the same path as on the host.
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
    USAGE = "usage: maf vm create [--cpus N] [--memory GIB] [--disk GIB] [--gem FILE]" \
            "|start|stop|delete|status|shell [COMMAND ...]"
    LIMACTL = "limactl"

    def initialize(argv, root)
      @action, *@args = argv
      @root = root
    end

    def run
      abort "maf: maf vm needs Lima. Install it: brew install lima" unless Shared::Harness.on_path?(LIMACTL)

      action = { "create" => :create, "shell" => :shell, "status" => :status }[@action]
      action ? send(action) : lifecycle
    end

    def name = "maf-#{File.basename(@root).downcase.gsub(/[^a-z0-9-]/, "-")}"

    private

    def lifecycle
      abort USAGE unless %w[start stop delete].include?(@action)

      limactl(@action, *("--force" if @action == "delete"), name)
    end

    def create
      template = Template.new(@root, VmOptions.parse(@args, @root))
      Tempfile.create(["maf-vm", ".yaml"]) { |file| create_from(file.path, template.render) }
      template.notes.each { |note| puts note }
    end

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
