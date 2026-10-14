# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    module Harness
      # VmCredential is one login file of a harness that maf vm can copy into the VM.
      class VmCredential
        attr_reader :dest

        def self.file(path, dest) = new(dest) { File.read(path) if File.file?(path) }

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

        def read
          @read.call
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
