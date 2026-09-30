# frozen_string_literal: true

module Bootstrap
  # MarkedBlock finds the tool-owned block in a file: from the first line that
  # contains MARKER to the next line that contains END_MARKER, inclusive. The
  # comment syntax around the markers differs per file (`#` vs `<!-- -->`), so
  # only the marker text is matched.
  class MarkedBlock
    def initialize(text)
      @lines = text.lines
    end

    def current?(block)
      range && @lines[range].join.strip == block.strip
    end

    def replace(block)
      return @lines.join unless range

      block = "#{block.chomp}\n"
      (@lines[0...range.begin] + [block] + @lines[(range.end + 1)..]).join
    end

    def remove
      return @lines.join unless range

      (@lines[0...range.begin] + @lines[(range.end + 1)..]).join
    end

    private

    def range
      @range ||= find_range
    end

    def find_range
      first = @lines.index { |line| line.include?(MARKER) }
      last = first && @lines[first..].index { |line| line.include?(END_MARKER) }
      last && (first..(first + last))
    end
  end
end
