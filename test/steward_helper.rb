# frozen_string_literal: true

# test/steward_helper.rb - a project folder with one registered worker for the steward tests.
require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "board_guard"

load File.expand_path("../assets/steward", __dir__)
load File.expand_path("../assets/coord", __dir__)

module StewardHelpers
  ID = "20261021T120000Z-a1b2c3"

  def setup
    @dir = File.realpath(Dir.mktmpdir("steward-test"))
    @home = Dir.pwd
    Dir.chdir(@dir)
    register_tester
  end

  def teardown
    Dir.chdir(@home)
    FileUtils.remove_entry(@dir)
  end

  def register_tester
    FileUtils.mkdir_p([".maf/coordination", ".maf/worktrees/tester-bot"])
    dir = File.join(@dir, ".maf/worktrees/tester-bot")
    workers("tester-bot" => { "role" => "tester", "worker_id" => "bot", "dir" => dir })
  end

  def workers(data) = File.write(".maf/coordination/workers.json", JSON.generate(data))
  def refused(name, *args) = assert_raises(Steward::Refused) { Steward::Ops.argv(name, args) }.message
  def events = File.read(".maf/coordination/events.log")

  def request(name, *args)
    path = ".maf/coordination/ops/done/#{ID}.json"
    FileUtils.mkdir_p(File.dirname(path))
    { "id" => ID, "op" => name, "args" => args, "role" => "", "path" => path }.tap do |req|
      File.write(path, JSON.generate(req))
    end
  end

  def handle(req, result: [true, "ok\n"], limit: Steward::Limit.new(File.join(@dir, "history.jsonl")))
    calls = []
    runner = ->(argv, _timeout) { (calls << argv) && result }
    Steward::Handler.new(req, runner: runner, limit: limit).run
    calls
  end

  def with_env(name, value)
    ENV[name] = value
    yield
  ensure
    ENV.delete(name)
  end
end
