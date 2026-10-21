# frozen_string_literal: true

# backup.rb - copies of the flow config in the git directory, and maf restore.
require "fileutils"
require "open3"
require "time"

module Maf
  # Backup keeps copies of the files in .maf/ that maf update cannot make again.
  # Each copy is a folder in .git/maf/backup/, so no checkout, merge, or reset
  # changes it. A copy is made only when config.json exists and the files differ
  # from the newest copy.
  class Backup
    FILES = %w[config.json roles.yml workflow.md sandbox.json].freeze
    KEEP = 10
    MISSING = "maf: .maf/config.json is missing. A backup from %<time>s has it. Run: maf restore"

    def initialize(root)
      @root = root
      @dir = git_dir&.then { |dir| File.join(dir, "maf", "backup") }
    end

    def save
      files = current
      return if @dir.nil? || !files.key?("config.json") || files == read(latest)

      write(File.join(@dir, Time.now.utc.strftime("%Y%m%dT%H%M%SZ")), files)
      prune
    end

    def snapshots = @dir ? Dir.glob(File.join(@dir, "*")).select { |path| File.directory?(path) }.sort : []
    def latest = snapshots.last
    def find(name) = snapshots.find { |path| File.basename(path) == name }
    def read(dir) = dir ? FILES.to_h { |name| [name, file(dir, name)] }.compact : {}
    def time(dir) = Time.strptime(File.basename(dir), "%Y%m%dT%H%M%S%z").localtime.strftime("%Y-%m-%d %H:%M")

    def warn_missing
      maf = File.join(@root, ".maf")
      return if !Dir.exist?(maf) || File.exist?(File.join(maf, "config.json")) || !read(latest).key?("config.json")

      warn format(MISSING, time: time(latest))
    end

    private

    def current = read(File.join(@root, ".maf"))
    def file(dir, name) = File.file?(File.join(dir, name)) ? File.read(File.join(dir, name)) : nil

    def write(dir, files)
      FileUtils.mkdir_p(dir)
      files.each { |name, text| File.write(File.join(dir, name), text) }
    end

    def prune = snapshots[0...-KEEP].each { |dir| FileUtils.rm_rf(dir) }

    def git_dir
      out, status = Open3.capture2("git", "-C", @root, "rev-parse", "--git-common-dir", err: File::NULL)
      status.success? ? File.expand_path(out.strip, @root) : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
