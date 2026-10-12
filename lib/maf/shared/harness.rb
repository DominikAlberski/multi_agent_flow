# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
#
# harness.rb loads the harness registry and every harness in harnesses/.
# To add a harness, add one file there. See harness/defaults.rb for the methods.
require_relative "harness/base"
require_relative "harness/traits"

Dir.glob(File.join(__dir__, "harnesses", "*.rb")).each { |file| require file }
