# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "digest"

module Maf
  module Shared
    module Sandbox
      # Seatbelt runs a command in a macOS sandbox-exec profile.
      module Seatbelt
        COMMAND = "/usr/bin/sandbox-exec"
        DEVICES = '(literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper") ' \
                  '(regex #"^/dev/tty") (regex #"^/dev/fd/") (regex #"^/dev/ptmx")'
        DNS = '(path-literal "/private/var/run/mDNSResponder")'
        TMP_PREFIX = "maf-sandbox-"
        SERVICES = "(deny mach-lookup (global-name-regex #\"^com\\.apple\\.(coreservices|lsd)\\.\"))\n" \
                   "(deny appleevent-send)\n"

        def self.wrap(cmd, paths)
          tmp = private_tmp(paths.root)
          [COMMAND, "-p", profile(paths, tmp), "env", "TMPDIR=#{tmp}/", "XDG_CACHE_HOME=#{tmp}/cache", *cmd]
        end

        def self.available? = File.executable?(COMMAND)
        def self.require! = available? || abort("maf: sandbox mode seatbelt needs #{COMMAND} (macOS only).")

        def self.private_tmp(root) = own_dir(project_tmp(root))

        def self.project_tmp(root)
          File.join(File.realpath("/tmp"), "#{TMP_PREFIX}#{Process.uid}-#{Digest::SHA256.hexdigest(root)[0, 12]}")
        end

        def self.own_dir(dir)
          make(dir)
          stat = File.lstat(dir)
          return dir if stat.directory? && stat.uid == Process.uid && stat.mode.nobits?(0o077)

          abort "maf: #{dir} belongs to another user or is open to others. Remove it."
        end

        def self.make(dir)
          Dir.mkdir(dir, 0o700)
        rescue Errno::EEXIST
          nil
        end

        def self.profile(paths, tmp)
          "(version 1)\n(allow default)\n(deny file-write*)\n#{writes(paths)}#{protects(paths)}" \
            "#{sockets([*paths.sockets, tmp])}#{SERVICES}"
        end

        def self.writes(paths)
          rules = paths.dirs.map { |dir| "(subpath #{quote(dir)})" } +
                  paths.prefixes.map { |prefix| "(prefix #{quote(prefix)})" } +
                  paths.state.filter_map { |pattern| regex(pattern) }
          "(allow file-write* #{DEVICES}\n  #{rules.join("\n  ")})\n"
        end

        def self.regex(pattern)
          return if pattern.include?('"')

          "(regex #\"^#{escape(pattern).gsub("*", "[^/]*")}(/|$)\")"
        end

        def self.escape(pattern) = pattern.gsub(/[.^$|()\[\]{}+?\\]/) { |char| "\\#{char}" }

        # A later rule wins, so these denials come after the allowed folders.
        def self.protects(paths)
          rules = paths.protected.map { |path| "(subpath #{quote(path)})" } +
                  paths.parents.map { |dir| "(literal #{quote(dir)})" }
          "(deny file-write*\n  #{rules.join("\n  ")})\n"
        end

        def self.sockets(dirs)
          allowed = [DNS, *dirs.map { |dir| "(subpath #{quote(dir)})" }]
          rules = allowed.map { |path| "(allow network-outbound (remote unix-socket #{path}))\n" }
          "(deny network-outbound (remote unix-socket))\n#{rules.join}"
        end

        def self.quote(path) = "\"#{path.gsub(/["\\]/) { |char| "\\#{char}" }}\""
      end
    end
  end
end
