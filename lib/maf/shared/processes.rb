# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    # Processes tells if a pid runs and when it started. A presence record
    # holds the start time, so every reader must get it the same way.
    module Processes
      PS_ENV = { "TZ" => "UTC", "LC_ALL" => "C" }.freeze

      # EPERM means the process exists but belongs to another user.
      def self.alive?(pid)
        pid.to_i.positive? && Process.kill(0, pid.to_i) && true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # The start time as ps prints it, or "" when ps fails.
      def self.started_at(pid)
        IO.popen(PS_ENV, ["ps", "-o", "lstart=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
      rescue SystemCallError
        ""
      end
    end
  end
end
