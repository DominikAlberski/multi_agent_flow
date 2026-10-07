# frozen_string_literal: true

# Rakefile - run the repo checks and the tests.
#
#   rake                               check, then test
#   rake check                         scripts/check.rb
#   rake test                          all test files
#   rake test TEST=test/coord_test.rb  one test file
#
# Each test file runs in its own Ruby process, as `ruby test/x_test.rb` does.
# The processes run in parallel. A failed file prints its full output.
# An agent session exports the variables of the shared board. The tests run
# without them, so a test never writes to that board.
require "etc"
require "open3"
require "rbconfig"

BOARD_ENV = %w[TASKRC COORD_DIR COORD_ROLE COORD_WORKER].to_h { |name| [name, nil] }.freeze

desc "Run the repo consistency checks"
task :check do
  ruby "scripts/check.rb"
end

desc "Run the tests (TEST=path runs one file)"
task :test do
  queue = Queue.new
  (ENV["TEST"] ? [ENV["TEST"]] : Dir["test/*_test.rb"].sort).each { |file| queue << file }
  queue.close
  results = Array.new(Etc.nprocessors) { Thread.new { run_tests(queue) } }.flat_map(&:value)
  failed = results.reject { |_, status, _| status.success? }
  failed.each { |file, _, out| puts "== #{file}", out }
  abort "rake: #{failed.size} test file(s) failed: #{failed.map(&:first).join(", ")}" unless failed.empty?
end

def run_tests(queue)
  results = []
  while (file = queue.pop)
    out, status = Open3.capture2e(BOARD_ENV, RbConfig.ruby, file)
    puts "#{status.success? ? "ok  " : "FAIL"} #{file}  #{out[/^\d+ runs.*$/]}"
    results << [file, status, out]
  end
  results
end

task default: %i[check test]
