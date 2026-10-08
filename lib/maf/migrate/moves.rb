# frozen_string_literal: true

module Maf
  module Migrate
    # Moves plans the move of scripts, folders, and the config file.
    class Moves
      def initialize(project)
        @project = project
      end

      def steps
        scripts + folders + config
      end

      private

      def scripts
        SCRIPTS.select { |old, _, signature| Migrate.signed?(path(old), signature) }
               .map { |old, new, _| move(old, new) }
      end

      def folders
        FOLDERS.select { |old, _| File.directory?(path(old)) }.map { |old, new| move(old, new) }
      end

      def config
        File.exist?(path(".agent-flow.json")) ? [move(".agent-flow.json", ".maf/config.json")] : []
      end

      def move(old, new)
        return Step.new("keep   #{old} (#{new} exists)", -> {}) if File.exist?(path(new))

        Step.new("move   #{old} -> #{new}", -> { relocate(path(old), path(new)) })
      end

      def relocate(from, to)
        FileUtils.mkdir_p(File.dirname(to))
        FileUtils.mv(from, to)
      end

      def path(*parts) = File.join(@project, *parts)
    end
  end
end
