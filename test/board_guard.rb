# frozen_string_literal: true

require "minitest"
require "open3"

# BoardGuard fails a suite run that changes the board named by TASKRC and COORD_DIR.
module BoardGuard
  def self.snapshot
    coord_dir = ENV["COORD_DIR"].to_s
    return nil if coord_dir.empty? || ENV["TASKRC"].to_s.empty?

    [tasks, Dir.glob(File.join(coord_dir, "inbox", "**", "*")).sort.map { |path| [path, File.size(path)] }]
  end

  def self.tasks
    out, = Open3.capture2e("task", "rc.confirmation=no", "export")
    out
  rescue Errno::ENOENT
    ""
  end

  BEFORE = snapshot

  Minitest.after_run do
    next if BEFORE.nil? || snapshot == BEFORE

    warn "BoardGuard: the test run changed the board in #{ENV["COORD_DIR"]}"
    exit 1
  end
end
