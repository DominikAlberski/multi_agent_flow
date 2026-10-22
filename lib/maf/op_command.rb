# frozen_string_literal: true

# op_command.rb - list, approve, or deny the host operations that wait for the user.
#
#   maf op list | approve ID | deny ID
require "rbconfig"
require_relative "team"

module Maf
  # OpCommand passes the command to .maf/bin/steward. Only the user runs it:
  # an approved operation runs on the host, outside the sandbox.
  class OpCommand
    USAGE = "usage: maf op list | approve ID | deny ID"
    AGENT = "maf: only the user approves host operations. Ask the user to run this command in a terminal."

    def initialize(argv, root)
      @argv = argv
      @root = root
    end

    def run
      abort AGENT if Team.agent?
      abort USAGE unless %w[list approve deny].include?(@argv.first)

      exec(RbConfig.ruby, File.join(@root, ".maf", "bin", "steward"), *@argv)
    end
  end
end
