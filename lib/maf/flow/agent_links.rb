# frozen_string_literal: true

module Flow
  # AgentLinks makes the folder of each harness a relative symlink into
  # .maf/agents/<harness>/. The harness reads its role files there. Each
  # link goes into the local git exclude: the flow is not a part of the project.
  class AgentLinks
    def initialize(project)
      @project = project
    end

    # Returns :create, :skip, or :refuse. :refuse means the folder holds files
    # that the flow does not own, or a symlink to another place.
    def link(harness)
      path = File.join(@project, HARNESS_DIRS.fetch(harness))
      return exclude(path) && :skip if linked?(path, harness)
      return :refuse unless free?(path)

      make(path, harness)
    end

    def self.target(harness)
      File.join("..", MAF_DIR, "agents", harness)
    end

    # A harness folder with the user's own files stays. Each role file gets a
    # relative symlink in it instead, so the harness still finds the role.
    # A user file with the same name stays, and its name is returned.
    def link_files(harness)
      dir = File.join(@project, HARNESS_DIRS.fetch(harness))
      prune(dir, harness)
      role_files(harness).reject { |source| link_file(dir, source) }.map { |source| File.basename(source) }
    end

    def self.file_target(harness, name) = File.join("..", "..", MAF_DIR, "agents", harness, name)

    private

    def linked?(path, harness)
      File.symlink?(path) && File.readlink(path) == self.class.target(harness)
    end

    def free?(path)
      return true unless File.exist?(path) || File.symlink?(path)

      File.directory?(path) && !File.symlink?(path) && Dir.empty?(path)
    end

    def role_files(harness) = Dir.glob(File.join(@project, MAF_DIR, "agents", harness, "*.md")).sort

    def link_file(dir, source)
      path = File.join(dir, File.basename(source))
      target = self.class.file_target(File.basename(File.dirname(source)), File.basename(source))
      # A link of an older install is in git status until it is excluded.
      return File.readlink(path) == target && exclude(path) if File.symlink?(path)

      !File.exist?(path) && File.symlink(target, path) && exclude(path)
    end

    def exclude(path) = LocalExclude.add(@project, path.delete_prefix("#{@project}/")) || true

    # A link of a removed role points nowhere. Remove it.
    def prune(dir, harness)
      prefix = File.join("..", "..", MAF_DIR, "agents", harness, "")
      Dir.glob(File.join(dir, "*.md")).each do |path|
        File.delete(path) if File.symlink?(path) && File.readlink(path).start_with?(prefix) && !File.exist?(path)
      end
    end

    def make(path, harness)
      Dir.rmdir(path) if File.directory?(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.symlink(self.class.target(harness), path)
      exclude(path) && :create
    end
  end
end
