#!/usr/bin/env ruby
# frozen_string_literal: true

# board-watch.rb - background board watcher for Claude Code sessions.
#
# Claude Code runs this script as an asyncRewake hook on SessionStart and on
# Stop. The hook process runs in the background. When the script exits with
# code 2, Claude Code shows its stderr to the model and starts a new turn,
# also in an idle session.
#
# Each interval, the script checks the session and the board:
# - If the session transcript changed in the last BOARD_WATCH_IDLE seconds,
#   the agent is running. The script does nothing.
# - If the agent is idle and the board has work for the role, the script
#   pokes the agent (stderr + exit 2) and ends.
# Work is: unclaimed tasks for the role, tasks that this worker claimed, and
# unread inbox messages. An unchanged poke repeats with a doubling delay.
#
# One watcher runs per worker (lock: coordination/locks/board-watch-<worker>.d).
# The script ends when its Claude Code process ends.
#
# Claude Code (.claude/settings.json), on SessionStart and on Stop:
#   {"type":"command","command":"ruby coordination/harness-hooks/board-watch.rb",
#    "async":true,"asyncRewake":true,"timeout":604800}
#
# Required env: COORD_ROLE (set by setup_agent). COORD_DIR and TASKRC optional.
# Env: BOARD_WATCH_INTERVAL (default 60), BOARD_WATCH_IDLE (default 120).
# The script does nothing if COORD_DISPATCHED is set: the dispatcher owns
# the loop for dispatched agents.
require "digest"
require "fileutils"
require "json"
require "rbconfig"

module BoardWatch
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
  MAX_BACKOFF = 3600
  PROMPT = "Board watcher: the task board has work for role %<role>s.\n%<summary>s\n" \
           "Run ./coord inbox, then ./coord next --mine, then ./coord next. " \
           "Finish claimed tasks first. Claim the next task and complete it. When no work remains, stop."

  # Work is one snapshot of the board for one worker.
  Work = Struct.new(:unclaimed, :claimed, :messages) do
    def any? = to_a.any? { |list| !list.empty? }
    def digest = Digest::SHA256.hexdigest(to_a.inspect)

    def summary
      { "unclaimed tasks" => unclaimed, "your claimed tasks" => claimed, "unread messages" => messages }
        .reject { |_label, list| list.empty? }.map { |label, list| "- #{label}: #{list.size}" }.join("\n")
    end
  end

  # Board reads work for one role and worker through the coord CLI.
  class Board
    def initialize(coord, env)
      @coord = coord
      @env = env
    end

    def work
      Work.new(task_ids("next", @env["COORD_ROLE"]), task_ids("next", "--mine"), messages)
    end

    private

    def task_ids(*args)
      output = IO.popen(@env, [RbConfig.ruby, @coord, *args], err: File::NULL, &:read).to_s
      output.lines.map(&:strip).grep(UUID).map { |line| line[UUID] }
    end

    def messages
      Dir.glob(File.join(@env["COORD_DIR"], "inbox", @env["COORD_ROLE"], "*.md")).map { |p| File.basename(p) }
    end
  end

  # Session tells if the agent is running: Claude Code appends to the
  # transcript while a turn runs.
  class Session
    def initialize(transcript, idle)
      @transcript = transcript.to_s
      @idle = idle
    end

    def running?
      File.exist?(@transcript) && Time.now - File.mtime(@transcript) < @idle
    end
  end

  # Owner is the Claude Code process that started the hook. A shell wrapper
  # between the two is skipped.
  class Owner
    SHELLS = %w[sh bash zsh dash].freeze

    def initialize(pid = Process.ppid)
      @pid = SHELLS.include?(command(pid)) ? parent(pid) : pid
    end

    def alive?
      @pid > 1 && Process.kill(0, @pid) && true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    private

    def command(pid) = File.basename(`ps -o comm= -p #{pid}`.strip)
    def parent(pid) = `ps -o ppid= -p #{pid}`.strip.to_i
  end

  # Lock makes sure only one watcher runs per worker. A lock whose process
  # is gone is stale and is taken over.
  class Lock
    def initialize(dir)
      @dir = dir
      @pid_file = File.join(dir, "pid")
    end

    def acquire
      take || (stale? && FileUtils.rm_rf(@dir) && take)
    end

    def release
      FileUtils.rm_rf(@dir) if File.exist?(@pid_file) && File.read(@pid_file).to_i == Process.pid
    end

    private

    def take
      FileUtils.mkdir_p(File.dirname(@dir))
      Dir.mkdir(@dir) && File.write(@pid_file, Process.pid) && true
    rescue Errno::EEXIST
      false
    end

    def stale?
      pid = File.exist?(@pid_file) ? File.read(@pid_file).to_i : 0
      pid <= 0 || !Process.kill(0, pid)
    rescue Errno::ESRCH
      true
    end
  end

  # Backoff stores the last poke of a worker. An unchanged poke repeats only
  # after a delay that doubles each time, up to MAX_BACKOFF.
  class Backoff
    def initialize(path, interval)
      @path = path
      @interval = interval
    end

    def due?(work)
      last = state
      last["digest"] != work.digest || Time.now.to_i - last["at"].to_i >= last["delay"].to_i
    end

    def record(work)
      last = state
      delay = last["digest"] == work.digest ? [last["delay"].to_i * 2, @interval].max : @interval
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.generate(digest: work.digest, at: Time.now.to_i, delay: [delay, MAX_BACKOFF].min))
    end

    private

    def state
      File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError
      {}
    end
  end

  Parts = Struct.new(:board, :session, :owner, :backoff, keyword_init: true)

  # Watcher sleeps one interval per check. It returns the work to poke
  # about, or nil if the owner process is gone.
  class Watcher
    def initialize(parts, interval)
      @parts = parts
      @interval = interval
    end

    def wait_for_work
      work = nil
      work = pokeable while work.nil? && @parts.owner.alive? && sleep(@interval)
      work
    end

    private

    def pokeable
      return nil if @parts.session.running?

      work = @parts.board.work
      work if work.any? && @parts.backoff.due?(work)
    end
  end

  # Main reads the environment and the hook input, runs one watcher, and
  # returns the exit code: 2 to poke the agent, 0 otherwise.
  class Main
    def initialize(env, input)
      @env = env
      @input = input
    end

    def run
      return 0 unless active? && lock.acquire

      work = watcher.wait_for_work
      lock.release
      work ? poke(work) : 0
    end

    private

    def active? = !role.empty? && role != "unknown" && !@env["COORD_DISPATCHED"] && coord
    def role = @env["COORD_ROLE"].to_s
    def worker = @env.fetch("COORD_WORKER", role)
    def coord_dir = File.expand_path(@env.fetch("COORD_DIR", "coordination"))
    def lock = @lock ||= Lock.new(File.join(coord_dir, "locks", "board-watch-#{worker}.d"))
    def backoff = @backoff ||= Backoff.new(File.join(coord_dir, "sessions", "#{worker}.watch.json"), interval)
    def interval = seconds("BOARD_WATCH_INTERVAL", 60)
    def seconds(name, default) = Integer(@env.fetch(name, default.to_s), exception: false) || default

    def coord
      @coord ||= [File.join(Dir.pwd, "coord"), File.join(File.dirname(coord_dir), "coord")]
                 .find { |path| File.executable?(path) }
    end

    def watcher
      session = Session.new(@input["transcript_path"], seconds("BOARD_WATCH_IDLE", 120))
      parts = Parts.new(board: Board.new(coord, board_env), session: session, owner: Owner.new, backoff: backoff)
      Watcher.new(parts, interval)
    end

    def board_env
      @env.to_h.merge("COORD_DIR" => coord_dir, "COORD_ROLE" => role, "COORD_WORKER" => worker,
                      "TASKRC" => @env.fetch("TASKRC", File.join(coord_dir, "taskrc")))
    end

    def poke(work)
      backoff.record(work)
      warn format(PROMPT, role: role, summary: work.summary)
      2
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  input = begin
    JSON.parse($stdin.read.to_s)
  rescue JSON::ParserError
    {}
  end
  exit BoardWatch::Main.new(ENV, input).run
end
