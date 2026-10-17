# frozen_string_literal: true

module Maf
  module Flow
    # EffortReport warns about an effort level that the harness does not list.
    module EffortReport
      def self.print(results)
        list = results.select { |r| r[:effort] && !harness(r).known_effort?(r[:effort], r[:model]) }
        return if list.empty?

        puts "", "WARNING: the harness does not list these effort levels. Check the level for a typo:",
             list.map { |r| "  #{name(r)} -> #{r[:effort]}" },
             "  Fix one with: maf add HARNESS:ROLE --effort ROLE=LEVEL"
      end

      def self.harness(result) = Harness.fetch(result[:agent][:harness])
      def self.name(result) = "#{result[:agent][:harness]}:#{result[:agent][:role]}"
    end
  end
end
