# frozen_string_literal: true

module SetupAgent
  # A role file that is not committed yet is missing in a new worktree, and
  # the harness then starts without its role. Copy the main checkout's file.
  module RoleFile
    def self.copy(root, dir, harness, role)
      relative = Flow.role_path(harness, role)
      source = relative && File.join(root, relative)
      return unless source && File.exist?(source) && !File.exist?(File.join(dir, relative))

      FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
      FileUtils.cp(source, File.join(dir, relative))
    end
  end
end
