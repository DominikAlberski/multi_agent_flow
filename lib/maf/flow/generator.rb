# frozen_string_literal: true

module Maf
  module Flow
    # Generator runs one maf add, remove, update, or roles command.
    class Generator
      # Flags that take a value. maf uses them to tell flag values from agent specs.
      def self.value_flags = Options.new([]).value_flags

      def initialize(argv)
        @options = Options.new(argv)
      end

      def run
        prepare
        return print_roles if @options.list_roles

        Validator.new(@options, @roles).run
        @options.agents.empty? ? finish_without_agents : generate_all
      end

      private

      def prepare
        @options.parse
        Validator.project!(@options)
        @catalog = RoleCatalog.new(@options.project)
        @roles = @catalog.roles
      end

      def generate_all
        Bootstrapper.new(@options).run
        results = RoleFiles.new(@options, @roles).generate
        HarnessLinker.new(@options).run
        McpInstaller.new(@options).install
        finish(results)
      end

      def finish(results)
        pending = @options.check? ? false : HookInstaller.new(@options.agents, @options.project).install
        manifest.write
        Report.new(@options.project, @roles, pending).print(results)
      end

      def manifest = Manifest.new(@options, @roles)

      def print_roles
        puts "Available roles (model_hint is a recommendation only):"
        @roles.each { |key, data| print_role(key, data) }
      end

      def print_role(key, data)
        puts "", "  #{key} (#{@catalog.source(key)})", "    #{data.fetch("description")}",
             "    model hint: #{data.fetch("model_hint")}"
      end

      def finish_without_agents
        manifest.write
        puts "No agents left. Add one: maf add HARNESS:ROLE. Remove the flow: maf uninstall."
      end
    end
  end
end
