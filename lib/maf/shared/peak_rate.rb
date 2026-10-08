# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.

module Maf
  module Shared
    # PeakRate knows the DeepSeek peak hours: 01:00-04:00 and 06:00-10:00 UTC,
    # Monday to Friday. The off-peak rate is half the peak rate. Chinese public
    # holidays are off-peak in full, but maf does not know them.
    module PeakRate
      HOURS = [1...4, 6...10].freeze

      # The peak hours that cover TIME (UTC), or nil off-peak.
      def self.hours(time) = time.wday.between?(1, 5) ? HOURS.find { |range| range.cover?(time.hour) } : nil
      def self.peak?(time) = !hours(time).nil?
    end
  end
end
