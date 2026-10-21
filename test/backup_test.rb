#!/usr/bin/env ruby
# frozen_string_literal: true

# test/backup_test.rb - tests for the flow config backup and maf restore.
#
# Run: ruby test/backup_test.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/maf/cli"

class BackupTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir("maf-backup-test"))
    system("git", "init", "-q", @root, exception: true)
    write("config.json", JSON.generate("agents" => [{ "harness" => "claude", "role" => "architect" }]))
    write("roles.yml", "mine: {}\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(name, text)
    FileUtils.mkdir_p(File.join(@root, ".maf"))
    File.write(File.join(@root, ".maf", name), text)
  end

  def read(name) = File.read(File.join(@root, ".maf", name))
  def backup = Maf::Backup.new(@root)
  def restore(*args) = capture_io { Maf::Restore.new(@root, args).run }.first

  def test_a_backup_lives_in_the_git_directory
    backup.save

    assert_equal File.join(@root, ".git", "maf", "backup"), File.dirname(backup.latest)
    assert_equal %w[config.json roles.yml], backup.read(backup.latest).keys
  end

  def test_no_backup_without_a_change
    2.times { backup.save }

    assert_equal 1, backup.snapshots.size
  end

  def test_a_change_makes_a_backup
    backup.save
    sleep 1.1
    write("roles.yml", "other: {}\n")
    backup.save

    assert_equal 2, backup.snapshots.size
  end

  def test_no_backup_without_config_json
    File.delete(File.join(@root, ".maf", "config.json"))
    backup.save

    assert_empty backup.snapshots
  end

  def test_only_the_newest_backups_stay
    dir = File.join(@root, ".git", "maf", "backup")
    12.times { |i| FileUtils.mkdir_p(File.join(dir, format("20260101T0000%02dZ", i))) }
    backup.save

    assert_equal Maf::Backup::KEEP, backup.snapshots.size
    refute_includes backup.snapshots.map { |path| File.basename(path) }, "20260101T000000Z"
  end

  def test_restore_keeps_a_file_that_exists_unless_forced
    backup.save
    write("roles.yml", "changed: {}\n")

    assert_includes restore, "keep     .maf/roles.yml"
    assert_equal "changed: {}\n", read("roles.yml")
  end

  def test_restore_puts_back_a_missing_file
    backup.save
    File.delete(File.join(@root, ".maf", "roles.yml"))

    assert_includes restore, "restore  .maf/roles.yml"
    assert_equal "mine: {}\n", read("roles.yml")
  end

  def test_list_names_each_backup_with_its_agents
    backup.save

    assert_match(/\A\d{8}T\d{6}Z  \S+ \S+  1 agents  config.json, roles.yml\n\z/, restore("--list"))
  end

  def test_an_unknown_backup_stops
    err = assert_raises(SystemExit) { restore("20990101T000000Z") }

    assert_includes err.message, "no backup 20990101T000000Z"
  end

  def test_the_warning_needs_a_partial_install
    backup.save
    File.delete(File.join(@root, ".maf", "config.json"))
    assert_includes capture_io { backup.warn_missing }.last, "Run: maf restore"

    FileUtils.rm_rf(File.join(@root, ".maf"))
    assert_empty capture_io { backup.warn_missing }.last
  end
end
