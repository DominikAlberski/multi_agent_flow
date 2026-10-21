# frozen_string_literal: true

# restore.rb - maf restore: put the flow config back from a backup.
require "fileutils"
require_relative "backup"

module Maf
  # Restore copies the files of a backup into .maf/. It keeps a file that
  # exists, unless --force is given. Then it runs maf update.
  class Restore
    USAGE = "usage: maf restore [--list] [BACKUP] [--force]"

    def initialize(root, argv)
      @root = root
      @backup = Backup.new(root)
      @list = argv.include?("--list")
      @force = argv.include?("--force")
      @name = argv.find { |arg| !arg.start_with?("-") }
    end

    def run
      return list if @list

      dir = @name ? @backup.find(@name) : @backup.latest
      abort(@name ? "maf: no backup #{@name}. Run: maf restore --list" : "maf: no backup in #{@root}") unless dir
      restore(dir)
    end

    private

    def list
      return puts("No backup yet. maf makes one when a maf command runs.") if @backup.snapshots.empty?

      @backup.snapshots.reverse_each { |dir| puts line(dir) }
    end

    def line(dir)
      files = @backup.read(dir)
      agents = JSON.parse(files.fetch("config.json", "{}")).fetch("agents", []).size
      "#{File.basename(dir)}  #{@backup.time(dir)}  #{agents} agents  #{files.keys.join(", ")}"
    rescue JSON::ParserError
      "#{File.basename(dir)}  #{@backup.time(dir)}  #{files.keys.join(", ")}"
    end

    def restore(dir)
      puts "Backup #{File.basename(dir)} (#{@backup.time(dir)}):"
      written = @backup.read(dir).select { |name, text| put(name, text) }
      return puts("Nothing to restore. --force replaces the files that exist.") if written.empty?

      Dir.chdir(@root) { Maf.flow } if written.key?("config.json")
    end

    def put(name, text)
      path = File.join(@root, ".maf", name)
      return puts("  keep     .maf/#{name} (exists; --force replaces it)") || false if File.exist?(path) && !@force

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      puts("  restore  .maf/#{name}") || true
    end
  end
end
