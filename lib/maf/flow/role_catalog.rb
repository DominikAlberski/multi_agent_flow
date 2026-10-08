# frozen_string_literal: true

module Maf
  module Flow
    # RoleCatalog merges the built-in roles with the project roles. A project
    # role in .maf/roles.yml adds a role or replaces a built-in role.
    class RoleCatalog
      FILE = ".maf/roles.yml"
      DEFAULTS = { "model_hint" => "", "can_edit" => true }.freeze

      def initialize(project)
        @project = project
      end

      def roles
        @roles ||= builtin.merge(custom.transform_values { |data| DEFAULTS.merge(data) })
      end

      def source(name)
        return "project" if custom.key?(name)

        "built-in"
      end

      def custom
        @custom ||= File.exist?(path) ? load_file(path) : {}
      end

      def path = File.join(@project, FILE)

      private

      def builtin = load_file(File.join(TEMPLATES, "roles.yml"))

      def load_file(file)
        YAML.safe_load_file(file).fetch("roles", nil) || {}
      end
    end
  end
end
