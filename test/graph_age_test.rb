#!/usr/bin/env ruby
# frozen_string_literal: true

# test/graph_age_test.rb - tests for `vault age` (the graph age).
#
# Run: ruby test/graph_age_test.rb
#
# The tests run assets/vault as a subprocess in a disposable git project.
# They skip when git is absent.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"

VAULT = File.expand_path("../assets/vault", __dir__)

class GraphAgeTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)
    @dir = File.realpath(Dir.mktmpdir("graph-age-test"))
    git("init", "-q")
    commit("a.rb", "a = 1\n", at: Time.now - 120)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(*args) = system("git", "-C", @dir, "-c", "user.email=t@t", "-c", "user.name=t", *args, exception: true)

# The commit date decides which commits come after the graph build.
def commit(name, text, at: Time.now)
  File.write(File.join(@dir, name), text)
  git("add", "-A")
  ENV["GIT_COMMITTER_DATE"] = at.to_s
  git("commit", "-q", "-m", name)
ensure
  ENV.delete("GIT_COMMITTER_DATE")
end

# The graph is one minute old. The first commit is two minutes old.
def build_graph
    path = File.join(@dir, "graphify-out", "graph.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}")
    File.utime(Time.now - 60, Time.now - 60, path)
  end

  def commit_later(name, text) = commit(name, text)

  def age(*args)
    out = IO.popen([RbConfig.ruby, VAULT, "age", *args], chdir: @dir, err: [:child, :out], &:read)
    [out, $?.exitstatus]
  end

  def test_a_missing_graph_is_reported
    out, status = age

    assert_equal 0, status, out
    assert_includes out, "graph age: missing"
  end

  def test_a_new_graph_is_fresh_with_zero_commits
    build_graph

    out, = age("--json")

    assert_equal({ "state" => "fresh", "commits" => 0 }, JSON.parse(out))
  end

  def test_a_source_commit_makes_the_graph_stale
    build_graph
    commit_later("b.rb", "b = 2\n")

    out, = age("--json")

    assert_equal({ "state" => "stale", "commits" => 1 }, JSON.parse(out))
  end

  def test_a_markdown_commit_makes_the_graph_stale
    build_graph
    commit_later("notes.md", "# Notes\n")

    assert_equal "stale", JSON.parse(age("--json").first).fetch("state")
  end

  def test_a_commit_of_other_files_keeps_the_graph_fresh_but_counts
    build_graph
    commit_later("data.csv", "1,2\n")

    assert_equal({ "state" => "fresh", "commits" => 1 }, JSON.parse(age("--json").first))
  end

  def test_the_text_form_counts_commits
    build_graph
    commit_later("b.rb", "b = 2\n")

    assert_includes age.first, "graph age: 1 commit since build (stale)"
  end

def test_age_in_a_worktree_reads_the_graph_of_the_main_project
  build_graph
  git("worktree", "add", "-q", "-b", "w", ".maf/worktrees/w")
  out = IO.popen([RbConfig.ruby, VAULT, "age", "--json"], chdir: File.join(@dir, ".maf", "worktrees", "w"), &:read)

  assert_equal "fresh", JSON.parse(out).fetch("state")
end

  def test_status_in_a_worktree_reports_the_graph_of_the_main_project
    build_graph
    git("worktree", "add", "-q", "-b", "w", ".maf/worktrees/w")
    out = IO.popen([RbConfig.ruby, VAULT, "status"], chdir: File.join(@dir, ".maf", "worktrees", "w"), err: [:child, :out], &:read)

    assert_includes out, "graph: graphify-out/graph.json\n"
    refute_includes out, "graph.json missing"
  end

  def test_status_shows_the_age
    out = IO.popen([RbConfig.ruby, VAULT, "status"], chdir: @dir, err: [:child, :out], &:read)

    assert_includes out, "graph age: missing"
  end
end

# The role files carry the rule: query the graph, and report a missing or stale graph.
class GraphPromptTest < Minitest::Test
  MAF = File.expand_path("../bin/maf", __dir__)

  def setup
    @dir = File.realpath(Dir.mktmpdir("graph-prompt-test"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def role_file(role)
    env = { "VAULT_SKIP" => "1", "TASKRC" => nil, "COORD_DIR" => nil }
    IO.popen(env, [RbConfig.ruby, MAF, "add", "opencode:#{role}", "--no-bootstrap"], chdir: @dir, err: %i[child out], &:read)
    File.read(File.join(@dir, ".maf", "agents", "opencode", "#{role}.md"))
  end

  def test_each_working_role_must_query_the_graph_and_report_its_state
    %w[architect backend-developer tester reviewer].each do |role|
      text = role_file(role)

      assert_includes text, "Query the shared knowledge graph when you start a task or plan a goal", role
      assert_equal 1, text.scan("Graph: fresh").size, role
      assert_includes text, "--budget 800", role
      refute_includes text, "If `graphify-out/` exists", role
    end
  end

  def test_the_architect_checks_the_graph_before_the_merge_suite
    assert_includes role_file("architect"), "check the graph with `vault age`"
  end
end
