# frozen_string_literal: true

module Maf
  module Flow
    # EffortReport warns about an effort level that the harness does not list,
    # and names the manual step for a harness that cannot take the effort.
    module EffortReport
      def self.print(results)
        set = results.select { |r| r[:effort] }
        warn_unknown(set.reject { |r| harness(r).known_effort?(r[:effort], r[:model]) })
        print_hints(set.filter_map { |r| hint_line(r) })
      end

      def self.warn_unknown(list)
        return if list.empty?

        puts "", "WARNING: the harness does not list these effort levels. Check the level for a typo:",
             list.map { |r| "  #{name(r)} -> #{r[:effort]}" },
             "  Fix one with: maf add HARNESS:ROLE --effort ROLE=LEVEL"
      end

      def self.print_hints(lines)
        puts "", "These harnesses cannot take the effort as it is. Set it in the harness:", lines unless lines.empty?
      end

      def self.hint_line(result)
        hint = harness(result).effort_hint(result[:effort])
        hint && "  #{name(result)} -> #{hint}"
      end

      def self.harness(result) = Harness.fetch(result[:agent][:harness])
      def self.name(result) = "#{result[:agent][:harness]}:#{result[:agent][:role]}"
    end
  end
end
