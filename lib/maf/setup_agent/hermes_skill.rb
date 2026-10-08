# frozen_string_literal: true

module Maf
  module SetupAgent
    # HermesSkill resolves the skill flow.rb generated for a role: the name is
    # <project>-<role>, and the dir is the manifest's hermes_dir (set by
    # `flow.rb --hermes-dir`) or flow.rb's default ~/.hermes/skills.
    module HermesSkill
      DEFAULT_DIR = File.join(Dir.home, ".hermes", "skills")

      # Plain defs, not endless ones: this file must still parse on Ruby 2.x so
      # the version check above can print its message.
      def self.name(role)
        "#{File.basename(Project.root)}-#{role}"
      end

      def self.dir
        Project.manifest.fetch("hermes_dir", DEFAULT_DIR)
      end

      def self.installed?(role)
        File.exist?(File.join(dir, name(role), "SKILL.md"))
      end
    end
  end
end
