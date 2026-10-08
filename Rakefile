# frozen_string_literal: true

# Rakefile - run the repo checks and the tests.
#
#   rake                               check, lint, then test
#   rake check                         scripts/check.rb
#   rake lint                          RuboCop (CI pins the version)
#   rake test                          all test files
#   rake test TEST=test/coord_test.rb  one test file
#   rake build / install / release    gem tasks of Bundler (pkg/maf-VERSION.gem)
#
# Each test file runs in its own Ruby process, as `ruby test/x_test.rb` does.
# The processes run in parallel. A failed file prints its full output.
# An agent session exports the variables of the shared board. The tests run
# without them, so a test never writes to that board.
# New git versions start a detached `git maintenance` after a commit. It can
# hold a lock file in a test repository while the test deletes it. The tests
# turn automatic maintenance off.
require "bundler/gem_tasks"
require "etc"
require "open3"
require "rbconfig"

BOARD_ENV = %w[TASKRC COORD_DIR COORD_ROLE COORD_WORKER].to_h { |name| [name, nil] }.freeze
GIT_ENV = { "GIT_CONFIG_COUNT" => "2", "GIT_CONFIG_KEY_0" => "maintenance.auto", "GIT_CONFIG_VALUE_0" => "false",
            "GIT_CONFIG_KEY_1" => "gc.auto", "GIT_CONFIG_VALUE_1" => "0" }.freeze
TEST_ENV = BOARD_ENV.merge(GIT_ENV).freeze

desc "Run the repo consistency checks"
task :check do
  ruby "scripts/check.rb"
end

desc "Run RuboCop"
task :lint do
  sh "rubocop", "--format", "simple" do |ok, _|
    ok || abort("rake: RuboCop failed. Fix the offenses. If rubocop is missing: gem install rubocop")
  end
end

desc "Run the tests (TEST=path runs one file)"
task :test do
  queue = Queue.new.tap { |q| test_files.each { |file| q << file } }.close
  failed = Array.new(Etc.nprocessors) { Thread.new { run_tests(queue) } }.flat_map(&:value)
  failed.each { |file, out| puts "== #{file}", out }
  abort "rake: #{failed.size} test file(s) failed: #{failed.map(&:first).join(", ")}" unless failed.empty?
end

def test_files = ENV["TEST"] ? [ENV["TEST"]] : Dir["test/*_test.rb"]

# Returns [file, output] for each failed file.
def run_tests(queue)
  Enumerator.produce { queue.pop }.take_while(&:itself).filter_map { |path| run_test(path) }
end

# Returns nil when the file passes.
def run_test(file)
  out, status = Open3.capture2e(TEST_ENV, RbConfig.ruby, file)
  puts "#{status.success? ? "ok  " : "FAIL"} #{file}  #{out[/^\d+ runs.*$/]}"
  [file, out] unless status.success?
end

task default: %i[check lint test]
