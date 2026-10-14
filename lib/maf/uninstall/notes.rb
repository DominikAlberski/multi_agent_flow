# frozen_string_literal: true

require_relative "../vm"

module Maf
  module Uninstall
    # Tells the user what the uninstaller keeps on purpose.
    class Notes
      def initialize(project) = @project = project

      def lines
        [kept_dirs, branches, global_hooks, vm].compact
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

      def vm
        return unless Maf::Shared::Harness.on_path?(Vm::LIMACTL)

        name = Vm.new([], @project).name
        "kept   the VM #{name} (delete with maf vm delete)" if vm_names.include?(name)
      end

      def vm_names = IO.popen([Vm::LIMACTL, "list", "--quiet"], err: File::NULL, &:readlines).map(&:strip)

      def global_hooks
        hooks = Uninstall.global_files.select { |path| File.exist?(path) }
        "kept   global hooks #{hooks.join(", ")} (other projects can use them)" if hooks.any?
      end
    end
  end
end
