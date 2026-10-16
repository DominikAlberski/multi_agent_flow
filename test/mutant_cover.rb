# frozen_string_literal: true

# `cover "Maf::X*"` in a test class tells rake mutant which code the class tests.
# Without the mutant gem the call does nothing.
require "minitest"
begin
  require "mutant/minitest/coverage"
rescue LoadError
  Minitest::Test.extend(Module.new { def cover(_expression) = nil })
end
