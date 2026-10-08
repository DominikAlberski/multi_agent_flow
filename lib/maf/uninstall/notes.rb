# frozen_string_literal: true

module Maf
  module Uninstall
    # Tells the user what the uninstaller keeps on purpose.
    class Notes
      def initialize(project) = @project = project

      def lines
        [kept_dirs, branches, global_hooks].compact
      end

      private

      def kept_dirs
        dirs = KEPT_DIRS.select { |dir| Dir.exist?(File.join(@project, dir)) }
        "kept   #{dirs.map { |d| "#{d}/" }.join(", ")} (costly to rebuild; delete by hand)" if dirs.any?
      end

      def branches
        list = Git.lines(@project, "branch", "--list", "worker/*", "--format=%(refname:short)")
        "kept   branches #{list.join(", ")} (delete with git branch -D)" if list.any?
      end

      def global_hooks
        hooks = GLOBAL_HOOKS.select { |path| File.exist?(path) }
        "kept   global hooks #{hooks.join(", ")} (other projects can use them)" if hooks.any?
      end
    end
  end
end
