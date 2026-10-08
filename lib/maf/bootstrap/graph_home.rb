# frozen_string_literal: true

module Maf
  module Bootstrap
    # GraphHome moves the graph of an older install from .maf/graphify-out/ to
    # graphify-out/ at the project root, and the vault from .maf/obsidian/ to
    # graphify-out/obsidian/. The vault watcher writes the graph, so it stops
    # first. VaultStarter starts it again after the move.
    class GraphHome
      OLD_GRAPH = File.join(MAF_DIR, "graphify-out")
      OLD_VAULT = File.join(MAF_DIR, "obsidian")
      VAULT = File.join(GRAPH_DIR, "obsidian")

      def initialize(project) = @project = project

      def move
        return unless Dir.exist?(path(OLD_GRAPH)) || Dir.exist?(path(OLD_VAULT))

        stop_watcher
        graph_moves = movable?(OLD_GRAPH, GRAPH_DIR)
        relocate(OLD_GRAPH, GRAPH_DIR) if graph_moves
        move_vault(graph_moves)
      end

      private

      # A graph at the root is newer than the old one, or belongs to the user. It stays.
      def movable?(old, new) = Dir.exist?(path(old)) && !kept?(old, new)

      # The moved graph folder can hold a stray vault that an agent exported.
      # The old scripts deleted it before each export, so the real vault replaces it.
      def move_vault(graph_moved)
        return unless Dir.exist?(path(OLD_VAULT))

        FileUtils.rm_rf(path(VAULT)) if graph_moved
        relocate(OLD_VAULT, VAULT) unless kept?(OLD_VAULT, VAULT)
      end

      # True when NEW exists. The old folder then stays where it is.
      def kept?(old, new)
        return false unless File.exist?(path(new))

        Bootstrap.say("keep   #{old} (#{new} exists)")
        true
      end

      def relocate(old, new)
        FileUtils.mkdir_p(File.dirname(path(new)))
        FileUtils.mv(path(old), path(new))
        Bootstrap.say("done   move #{old} -> #{new}")
      end

      def stop_watcher
        script = @project.bin_path("vault")
        pid = path(MAF_DIR, "coordination", "vault.pid")
        system(script, "stop", chdir: @project.target, out: File::NULL) if File.exist?(pid) && File.exist?(script)
      end

      def path(*parts) = @project.path(*parts)
    end
  end
end
