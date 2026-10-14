# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "fileutils"

module Maf
  module Shared
    module Sandbox
      # Bwrap runs a command in a Linux bubblewrap sandbox.
      module Bwrap
        COMMAND = "bwrap"
        MARKER = "MAF_BWRAP"
        BASE = ["--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev", "--tmpfs", "/dev/shm", "--proc", "/proc",
                "--tmpfs", "/tmp", "--setenv", MARKER, "1"].freeze
        MASKED_DIRS = %w[/run/user /run/dbus].freeze
        MASKED_SOCKETS = %w[/run/docker.sock /run/podman/podman.sock /run/containerd/containerd.sock].freeze
        HOOK = "# Project hook for coord worktree. See assets/worktree-env.example.rb in the maf gem.\n"

        def self.wrap(cmd, paths)
          return cmd if inside?

          [binary, *BASE, *masks, *home, *binds(paths), *protects(paths), "--die-with-parent", "--", *cmd]
        end

        def self.available? = !binary.nil?

        def self.binary
          dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject { |dir| agent_dir?(File.expand_path(dir)) }
          dirs.map { |dir| File.join(dir, COMMAND) }.find { |file| File.executable?(file) }
        end

        def self.agent_dir?(dir)
          writes = Array(Sandbox.policy["write"]).map { |path| File.expand_path(path, Project.root) }
          tops = [Project.root, "/tmp", "/var/tmp", ENV.fetch("TMPDIR", nil), *writes].compact.map { _1.chomp("/") }
          tops.any? { |top| dir == top || dir.start_with?("#{top}/") }
        end

        def self.require!
          inside? || (available? && overlay?) || abort("maf: sandbox mode bwrap needs bubblewrap 0.10 or later.")
        end

        def self.inside?(mountinfo = "/proc/self/mountinfo")
          ENV[MARKER] == "1" && File.foreach(mountinfo).any? { |line| home_overlay?(line) }
        rescue SystemCallError
          false
        end

        # mountinfo writes a space in a path as \040.
        def self.home_overlay?(line) = line.include?(" #{mount_path(Dir.home)} ") && line.include?(" - overlay ")
        def self.mount_path(path) = path.gsub(" ", "\\\\040")

        def self.masks
          runtime = ENV.fetch("XDG_RUNTIME_DIR", "")
          MASKED_DIRS.select { |dir| File.directory?(dir) }.flat_map { |dir| ["--tmpfs", dir] } +
            (runtime.start_with?("/run/user/") ? ["--dir", runtime] : []) +
            MASKED_SOCKETS.select { |path| File.exist?(path) }.flat_map { |path| ["--ro-bind", "/dev/null", path] }
        end

        def self.home = ["--overlay-src", Dir.home, "--tmp-overlay", Dir.home]
        def self.overlay? = IO.popen([binary, "--help"], err: %i[child out], &:read).include?("--tmp-overlay")

        def self.binds(paths)
          FileUtils.mkdir_p(paths.harness_dirs)
          paths.prefixes.each { |file| File.exist?(file) || File.write(file, "{}\n") }
          writable(paths).select { |path| File.exist?(path) }.flat_map { |path| ["--bind", path, path] }
        end

        def self.writable(paths)
          ((paths.dirs - ["/tmp"]) + paths.harness_dirs + paths.prefixes).reject { |path| masked?(path) }
        end

        def self.masked?(path)
          (MASKED_DIRS + MASKED_SOCKETS).any? do |mask|
            path == mask || path.start_with?("#{mask}/") || mask.start_with?("#{path.chomp("/")}/")
          end
        end

        # A mount point cannot be renamed, so each parent folder is bound onto itself.
        # Then each protected path is bound read-only.
        def self.protects(paths)
          create_protected(paths)
          parents = bound_parents(paths).select { |dir| File.directory?(dir) }.flat_map { |dir| ["--bind", dir, dir] }
          parents + paths.protected.select { |path| File.exist?(path) }.flat_map { |path| ["--ro-bind", path, path] }
        end

        def self.bound_parents(paths)
          tops = writable(paths)
          paths.parents.select { |dir| tops.any? { |top| dir == top || dir.start_with?("#{top.chomp("/")}/") } }
        end

        # A bind needs an existing path. Else the agent could create a protected
        # path, so the folders, the worktree hook, and the harness config are created first.
        def self.create_protected(paths)
          paths.protected_dirs.each { |dir| make(dir) }
          create_hook(paths.coord_file("worktree-env.rb"))
          paths.placeholders.each { |path| placeholder(path) }
        end

        def self.create_hook(hook)
          File.exist?(File.dirname(hook)) && !File.exist?(hook) && File.write(hook, HOOK)
        end

        def self.placeholder(path)
          return if File.exist?(path) || File.symlink?(path) || !File.directory?(File.dirname(path))

          name = File.basename(path)
          File.extname(name).empty? && !name.start_with?(".") ? make(path) : write(path, empty_text(name))
        end

        def self.write(path, text)
          File.write(path, text)
        rescue SystemCallError
          nil
        end

        def self.empty_text(name) = name.end_with?(".json", ".jsonc") ? "{}\n" : ""

        def self.make(dir)
          FileUtils.mkdir_p(dir)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
