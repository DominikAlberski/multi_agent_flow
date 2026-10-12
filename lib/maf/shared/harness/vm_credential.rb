# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    module Harness
      # VmCredential is one login file of a harness. maf vm copies it into the VM
      # only after the user agrees. dest is relative to the home folder in the VM.
      class VmCredential
        attr_reader :dest

        # A file on the host, for example ~/.codex/auth.json.
        def self.file(path, dest) = new(dest) { File.read(path) if File.file?(path) }

        # A generic password in the macOS Keychain. macOS can ask the user to allow the access.
        def self.keychain(service, dest)
          new(dest) do
            text = IO.popen(["security", "find-generic-password", "-s", service, "-w"], err: File::NULL, &:read)
            text unless text.to_s.strip.empty?
          end
        end

        def initialize(dest, &read)
          @dest = dest
          @read = read
        end

        # The text of the login, or nil if the host has no login.
        def read
          @read.call
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
