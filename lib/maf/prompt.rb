# frozen_string_literal: true

module Maf
  # Prompt asks questions on a terminal. The user picks items by number.
  # Each question returns nil at the end of the input.
  class Prompt
    def initialize(input = $stdin, output = $stdout)
      @input = input
      @output = output
    end

    def say(text) = @output.puts(text)

    def ask(question)
      @output.print("#{question} ")
      @input.gets&.strip
    end

    def choose(title, items)
      show(items)
      pick(ask("#{title}:"), items)
    end

    def choose_many(title, items)
      show(items)
      ask("#{title} (numbers, comma separated):").to_s.split(",").filter_map { |answer| pick(answer, items) }
    end

    def confirm?(question) = ask("#{question} [y/N]").to_s.downcase == "y"

    private

    def show(items) = items.each_with_index { |item, i| say("  #{i + 1}) #{item}") }

    def pick(answer, items)
      number = Integer(answer.to_s.strip, exception: false)
      number&.between?(1, items.size) ? items[number - 1] : say("invalid choice")
    end
  end
end
