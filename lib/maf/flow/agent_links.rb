# frozen_string_literal: true

module Flow
  # AgentLinks makes the folder of each harness a relative symlink into
  # .maf/agents/<harness>/. The harness reads its role files there. Git
  # tracks the symlink.
  class AgentLinks
    def initialize(project)
      @project = project
    end

    # Returns :create, :skip, or :refuse. :refuse means the folder holds files
    # that the flow does not own, or a symlink to another place.
    def link(harness)
      path = File.join(@project, HARNESS_DIRS.fetch(harness))
      return :skip if linked?(path, harness)
      return :refuse unless free?(path)

      make(path, harness)
    end

    def self.target(harness)
      File.join("..", MAF_DIR, "agents", harness)
    end

    private

    def linked?(path, harness)
      File.symlink?(path) && File.readlink(path) == self.class.target(harness)
    end

    def free?(path)
      return true unless File.exist?(path) || File.symlink?(path)

      File.directory?(path) && !File.symlink?(path) && Dir.empty?(path)
    end

    def make(path, harness)
      Dir.rmdir(path) if File.directory?(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.symlink(self.class.target(harness), path)
      :create
    end
  end
end
