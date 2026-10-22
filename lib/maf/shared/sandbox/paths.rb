# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "../project"
require_relative "references"
require_relative "harness_files"

module Maf
  module Shared
    module Sandbox
      # Paths holds the real paths of a sandbox.
      class Paths
        COMMON = ["/tmp", "/var/tmp"].freeze
        PROTECTED = [".maf/sandbox.json", ".maf/bin", ".maf/lib", ".maf/env.sh", ".maf/coordination/harness-hooks",
                     ".maf/claude", ".maf/mcp", ".git/hooks", ".git/config", ".git/commondir",
                     ".git/config.worktree"].freeze
        COORD_PROTECTED = %w[message-hooks taskrc worktree-env.rb taskdata/hooks].freeze
        COORD_DIRS = %w[message-hooks taskdata/hooks].freeze
        PROTECTED_DIRS = [".maf/bin", ".maf/lib", ".maf/claude", ".maf/mcp", ".git/hooks"].freeze
        WORKTREE_PROTECTED = [".maf/bin", ".maf/lib", ".maf/env.sh", ".maf/coordination/harness-hooks"].freeze
        FLOW_CONFIG = %w[.maf/claude/settings.json .maf/mcp/*.json].freeze

        attr_reader :root

        def initialize(harnesses, root, coord_dir, policy)
          @harness = HarnessFiles.new(harnesses, ->(paths) { real(paths) })
          @root = root
          @coord_dir = coord_dir || File.join(root, ".maf", "coordination")
          @extra = Array(policy["write"]).map { |path| File.expand_path(path, root) }
          @app_paths = Array(policy["launch_services"]).map { |path| File.expand_path(path, root) }
        end

        def dirs = @dirs ||= real([@root, @coord_dir, *@extra, ENV.fetch("TMPDIR", nil), *COMMON])
        def harness_dirs = @harness.dirs
        def state = @harness.state
        def harness_files = @harness.locked
        def placeholders = @harness.placeholders
        def prefixes = @harness.prefixes

        def references
          keep = ->(path) { writable?(path) }
          References.of(@harness.config + project_config + flow_config, @root, keep) +
            worktrees.flat_map { |dir| References.of(config_in(dir), dir, keep) }
        end

        def existing = dirs.select { |dir| File.exist?(dir) }

        def apps = @apps ||= real(@app_paths).select { |path| File.exist?(path) }.each { |path| fixed_app!(path) }

        def fixed_app!(path)
          writable?(path) && abort("maf: #{path} in launch_services is in a folder that the agent can change.")
        end

        def sockets = real([@root, @coord_dir])

        def protected
          @protected ||= begin
            paths = [*PROTECTED.map { |path| File.join(@root, path) }, *project_config, *coord_files, *worktree_links,
                     *worktree_files, *submodule_files, *harness_files, *references]
            (real(paths) + links(paths)).uniq
          end
        end

        def project_config = config_in(@root)
        def config_in(dir) = Harness.all.flat_map(&:sandbox_project).uniq.map { |path| File.join(dir, path) }
        def flow_config = FLOW_CONFIG.flat_map { |glob| Dir.glob(File.join(@root, glob)) }

        def protected_dirs
          real([*PROTECTED_DIRS.map { |path| File.join(@root, path) }, *COORD_DIRS.map { |name| coord_file(name) }])
        end

        def coord_files = COORD_PROTECTED.map { |name| coord_file(name) }
        def coord_file(name) = File.join(@coord_dir, name)

        def worktree_links
          Dir.glob(File.join(@root, Project::WORKTREES_DIR, "*", ".git")) +
            Dir.glob(File.join(@root, ".git", "worktrees", "*", "{commondir,gitdir,config.worktree}"))
        end

        def worktree_files
          worktrees.flat_map do |dir|
            [*WORKTREE_PROTECTED.map { |path| File.join(dir, path) }, *config_in(dir)]
          end
        end

        GIT_FILES = %w[config hooks].freeze

        def submodule_files
          dirs = Dir.glob(File.join(@root, ".git", "modules", "**", "HEAD")).map { |head| File.dirname(head) }
          dirs = dirs.select { |dir| File.file?(File.join(dir, "config")) }
          dirs.flat_map { |dir| GIT_FILES.map { |name| File.join(dir, name) } }
        end

        def worktrees = Dir.glob(File.join(@root, Project::WORKTREES_DIR, "*"))

        def parents
          protected.flat_map { |path| parents_of(path) }.uniq.sort_by(&:size)
        end

        private

        def parents_of(path)
          top = (dirs + harness_dirs).select { |dir| path.start_with?("#{dir}/") }.max_by(&:size)
          top ? ancestors(path).take_while { |dir| dir.size >= top.size } : []
        end

        def writable?(path)
          real_path = real([path]).first
          dirs.any? { |dir| real_path.start_with?("#{dir}/") }
        end

        def ancestors(path) = (dir = File.dirname(path)) == path ? [] : [dir, *ancestors(dir)]
        def real(paths) = paths.compact.reject(&:empty?).map { |path| resolve(File.expand_path(path)) }.uniq

        def resolve(path)
          File.realpath(path)
        rescue SystemCallError
          File.exist?(File.dirname(path)) ? in_real_dir(path) : path
        end

        def links(paths)
          symlinks = paths.map { |path| File.expand_path(path) }.select { |path| File.symlink?(path) }
          symlinks.map { |link| in_real_dir(link) }
        end

        def in_real_dir(path) = File.join(File.realpath(File.dirname(path)), File.basename(path))
      end
    end
  end
end
