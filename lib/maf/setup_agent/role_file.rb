# frozen_string_literal: true

module SetupAgent
  # A role file that is not committed yet is missing in a new worktree, and
  # the harness then starts without its role. Copy the main checkout's file.
  # The worktree also needs the symlink from the harness folder to the file.
  module RoleFile
    def self.copy(root, dir, harness, role)
      relative = Flow.role_path(harness, role)
      return unless relative

      copy_missing(File.join(root, relative), File.join(dir, relative))
      Flow::AgentLinks.new(dir).link(harness)
    end

    def self.copy_missing(source, dest)
      return unless File.exist?(source) && !File.exist?(dest)

      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(source, dest)
    end
  end
end
