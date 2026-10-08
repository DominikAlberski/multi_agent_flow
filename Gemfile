# frozen_string_literal: true

source "https://rubygems.org"

# The runtime dependencies are in maf.gemspec.
gemspec

gem "irb"
gem "minitest", ">= 5.16"
gem "rake", "~> 13.0"

# CI pins the RuboCop version. Raise it on purpose, then fix the new offenses.
# The test jobs skip this group (BUNDLE_WITHOUT=lint).
group :lint do
  gem "rubocop", "1.91.0"
end
