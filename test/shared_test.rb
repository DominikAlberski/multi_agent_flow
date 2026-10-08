#!/usr/bin/env ruby
# frozen_string_literal: true

# test/shared_test.rb - tests for lib/maf/shared/, the library that the maf CLI
# and the installed scripts share.
#
# Run: ruby test/shared_test.rb
require "minitest/autorun"
require "rbconfig"
require "open3"
require_relative "../lib/maf/bootstrap"
require "tmpdir"
require_relative "../lib/maf/shared/processes"
require_relative "../lib/maf/shared/project"
require_relative "../lib/maf/shared/git_exclude"
require_relative "../lib/maf/shared/peak_rate"
require_relative "../lib/maf/shared/git_identity"

SHARED_FILES = Dir[File.expand_path("../lib/maf/shared/*.rb", __dir__)]

# An installed script loads one shared file with no load path and no gems.
class SharedLoadTest < Minitest::Test
  def test_each_file_loads_alone_with_the_stdlib
    SHARED_FILES.each do |file|
      out, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", "-e", "require ARGV[0]", file)
      assert status.success?, "#{File.basename(file)}: #{out}"
    end
  end

  # The installer and the uninstaller know a shared file by this signature.
  def test_each_file_carries_the_signature
    SHARED_FILES.each { |file| assert_includes File.read(file), Maf::Bootstrap::SHARED_SIGNATURE, file }
  end
end

class ProcessesTest < Minitest::Test
  Processes = Maf::Shared::Processes

  def test_the_current_process_is_alive
    assert Processes.alive?(Process.pid)
  end

  def test_a_pid_that_is_not_positive_is_not_alive
    [0, -1, nil, ""].each { |pid| refute Processes.alive?(pid), pid.inspect }
  end

  def test_an_ended_process_is_not_alive
    pid = Process.spawn(RbConfig.ruby, "-e", "exit")
    Process.wait(pid)

    refute Processes.alive?(pid)
    assert_equal "", Processes.started_at(pid)
  end

  # pid 1 belongs to root. kill(0) on it raises EPERM for other users.
  def test_a_process_of_another_user_is_alive
    skip "runs as root" if Process.uid.zero?

    assert Processes.alive?(1)
  end

  def started_in(zone)
    old = ENV.fetch("TZ", nil)
    ENV["TZ"] = zone
    Processes.started_at(Process.pid)
  ensure
    ENV["TZ"] = old
  end

  def test_the_start_time_does_not_depend_on_the_time_zone
    tokyo = started_in("Asia/Tokyo")

    refute_empty tokyo
    assert_equal tokyo, started_in("UTC")
  end
end

class PeakRateTest < Minitest::Test
  PeakRate = Maf::Shared::PeakRate

  # 2026-10-07 is a Wednesday, 2026-10-10 a Saturday.
  def at(text) = Time.utc(*text.split(/[- :]/).map(&:to_i))

  def test_peak_hours_on_a_weekday
    assert PeakRate.peak?(at("2026-10-07 01:00"))
    assert PeakRate.peak?(at("2026-10-07 09:59"))
    refute PeakRate.peak?(at("2026-10-07 04:00"))
    refute PeakRate.peak?(at("2026-10-07 10:00"))
  end

  def test_the_weekend_is_off_peak
    refute PeakRate.peak?(at("2026-10-10 07:00"))
  end

  def test_hours_gives_the_end_of_the_peak
    assert_equal 10, PeakRate.hours(at("2026-10-07 07:30")).end
    assert_nil PeakRate.hours(at("2026-10-07 12:00"))
  end
end

class ProjectTest < Minitest::Test
  Project = Maf::Shared::Project

  def test_worktree_dir
    assert_equal "/p/.maf/worktrees/tester-1", Project.worktree_dir("/p", "tester-1")
  end

  def git(dir, *args) = system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", *args, exception: true)

  # From a linked worktree, root is the main checkout.
  def test_root_from_a_worktree
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      [%w[init -q], %w[commit -q --allow-empty -m i], %w[worktree add -q wt]].each { |args| git(root, *args) }
      assert_equal root, Dir.chdir(File.join(root, "wt")) { Project.root }
    end
  end

  def test_manifest_is_empty_without_a_config
    Dir.mktmpdir { |dir| assert_equal({}, Dir.chdir(dir) { Project.manifest }) }
  end
end

class GitExcludeTest < Minitest::Test
  # A relative path would break a caller that runs in another directory.
  def test_the_path_is_absolute
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", exception: true)
      path = Maf::Shared::GitExclude.path(dir)
      assert File.absolute_path?(path) && path.end_with?(".git/info/exclude"), path
    end
  end

  def test_no_path_outside_a_repository_warns
    Dir.mktmpdir do |dir|
      assert_output(nil, /no git exclude file/) { assert_nil Maf::Shared::GitExclude.path(dir) }
    end
  end

  # Every worktree shares the exclude file of the main clone.
  def test_a_worktree_gets_the_exclude_file_of_the_main_clone
    Dir.mktmpdir do |dir|
      main = File.join(dir, "main")
      tree = worktree(main, File.join(dir, "tree"))
      assert_equal File.realpath(File.join(main, ".git/info")), File.realpath(File.dirname(git_exclude(tree)))
    end
  end

  def worktree(main, tree)
    system("git", "init", "-q", main, exception: true)
    system("git", "-C", main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty",
           "-m", "init", exception: true)
    system("git", "-C", main, "worktree", "add", "-q", tree, exception: true)
    tree
  end

  def git_exclude(dir) = Maf::Shared::GitExclude.path(dir)

  # Git before 2.31 has no --path-format and gives a path relative to the directory.
  def test_git_without_path_format_gives_an_absolute_path
    Dir.mktmpdir do |dir|
      fake_git(dir)
      path = with_path(File.join(dir, "bin")) { git_exclude(dir) }
      assert_equal File.join(dir, ".git/info/exclude"), path
    end
  end

  OLD_GIT = <<~SH
    #!/bin/sh
    for arg in "$@"; do [ "$arg" = "--path-format=absolute" ] && { echo "$arg"; exit 129; }; done
    echo .git/info/exclude
  SH

  def fake_git(dir)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "git"), OLD_GIT)
    File.chmod(0o755, File.join(dir, "bin", "git"))
  end

  def with_path(bin)
    old = ENV.fetch("PATH")
    ENV["PATH"] = "#{bin}:#{old}"
    yield
  ensure
    ENV["PATH"] = old
  end
end

class GitIdentityTest < Minitest::Test
  BOT = { "github" => { "bot_user" => "maf-bot", "bot_email" => "bot@example.com" } }.freeze

  def identity(config) = Maf::Shared::GitIdentity.env(config)

  def test_git_identity_sets_the_author_and_the_committer
    env = identity("git_identity" => { "name" => "Agent", "email" => "agent@example.com" })

    assert_equal %w[Agent agent@example.com Agent agent@example.com],
                 env.values_at("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL")
  end

  def test_git_identity_wins_over_the_github_bot
    env = identity(BOT.merge("git_identity" => { "name" => "Agent", "email" => "agent@example.com" }))

    assert_equal "Agent", env["GIT_AUTHOR_NAME"]
  end

  def test_the_github_bot_is_the_fallback
    assert_equal "maf-bot", identity(BOT)["GIT_COMMITTER_NAME"]
  end

  # Without a persona, git uses the config of the user.
  def test_no_persona_sets_nothing
    assert_empty identity({})
    assert_empty identity("git_identity" => { "name" => "Agent" })
  end
end
