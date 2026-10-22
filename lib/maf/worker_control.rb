# frozen_string_literal: true

# worker_control.rb - stop, start, or restart one worker. The dashboard calls it.
require "json"
require "fileutils"
require "rbconfig"
require_relative "workers"
require_relative "retire"
require_relative "role_limits"
require_relative "shared/processes"
require_relative "session_records"

module Maf
  # WorkerControl stops, starts, or restarts one worker. Each action is
  # idempotent: start on a live worker and stop on a stopped worker do nothing.
  # A dispatched worker runs in the background, so maf starts it again. An
  # interactive worker runs in the user's terminal, so maf only stops it, and
  # only when the session is idle. maf then prints the start command.
  class WorkerControl
    ACTIONS = %w[status stop start restart].freeze
    USAGE = "usage: maf worker list | #{ACTIONS.join("|")} ROLE[_WORKER] [--force] " \
            "[--max-context N] [--max-session-runs N] [--cache-window S]".freeze
    MAF = File.expand_path("../../exe/maf", __dir__)
    IDLE = 60
    STUCK = "maf: %<worker>s did not stop after TERM. Its terminal may be closed. " \
            "Stop it with: pkill -9 -P %<pid>s; kill -9 %<pid>s"

    # force stops an interactive session also when maf cannot tell if it is idle.
    # limits are session limits of the role. start and restart save them first.
    def initialize(root, spec, force: false, limits: {})
      @root = root
      @force = force
      @limits = limits
      @worker = resolve(Workers.at(root).all, Workers.id(spec))
      @entry = Workers.at(root).find(@worker) || abort("maf: no worker #{@worker}")
    end

    def run(action)
      abort "usage: maf worker #{ACTIONS.join("|")} ROLE[_WORKER]" unless ACTIONS.include?(action)

      RoleLimits.new(@root).save(@entry["role"], @limits) if %w[start restart].include?(action)
      ControlLock.new(File.join(coord_dir, "locks", "control-#{@worker}.d")).hold { send(action) }
    end

    private

    def resolve(workers, worker)
      return worker if workers.key?(worker)

      only_worker(worker, workers.select { |_, entry| entry["role"] == worker }.keys) || worker
    end

    def only_worker(role, names)
      abort "maf: role #{role} has more than one worker: #{names.join(", ")}. Name one." if names.size > 1
      names.first
    end

    def status = puts("#{@worker}: #{live? ? "running (pid #{pid})" : "stopped"}")

    def stop
      return puts("#{@worker} is already stopped.") unless live?

      abort "maf: #{@worker}: maf cannot check pid #{pid}. Stop it with: kill #{pid}" unless ours?

      @entry["dispatch"] ? stop_dispatcher : stop_session
    end

    def start
      return puts("#{@worker} already runs (pid #{pid}).") if live?

      @entry["dispatch"] ? start_dispatcher : puts(start_hint)
    end

    def restart
      stop
      start
    end

    # TERM lets a running agent finish its run. The dispatcher then exits.
    def stop_dispatcher
      puts "Stopping #{@worker} (pid #{pid}). A running agent finishes its run first."
      RunningProcesses.terminate(pid)
      abort "maf: pid #{pid} did not stop. Stop it with: kill #{pid}" unless RunningProcesses.wait_for_exit(pid)
    end

    # A session in a turn would lose its work. The hook writes the transcript in each turn.
    def stop_session
      abort "maf: #{@worker} is in a turn. Try again when the session is idle." if busy?
      abort "maf: maf cannot tell if #{@worker} is idle. Stop it in its terminal, or add --force." if unknown?

      terminate_session
    end

    def terminate_session
      RunningProcesses.terminate(pid)
      abort format(STUCK, worker: @worker, pid: pid) unless RunningProcesses.wait_for_exit(pid, timeout: 10)
      puts "Stopped #{@worker}. To start it again: #{start_hint}"
    end

    def start_dispatcher
      args = SetupAgent.start_args(@entry) + ["--detach"]
      system(RbConfig.ruby, MAF, "start", *args, chdir: @root) || abort("maf: #{@worker} did not start")
    end

    def start_hint = "cd #{@entry["dir"]} && maf start"
    def coord_dir = File.join(@root, ".maf", "coordination")
    def presence = @presence ||= SessionRecords.new(coord_dir).find(@worker) || presence_file
    def presence_file = read(File.join(coord_dir, "presence", "#{@worker}.json"))
    def pid = presence["pid"].to_i
    def live? = Shared::Processes.live?(presence)
    def ours? = Shared::Processes.same?(pid, presence["started"])

    # The context-watch hook records the transcript of Claude Code and Codex
    # sessions. opencode has no such hook, so its idle state is unknown.
    def transcript = read(File.join(coord_dir, "status", "#{@worker}.json"))["transcript"].to_s
    def busy? = File.exist?(transcript) && Time.now - File.mtime(transcript) < IDLE
    def unknown? = !@force && !File.exist?(transcript)

    def read(path)
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end
  end

  # ControlLock runs one control action per worker at a time. A second click
  # in the dashboard does not start a second dispatcher. The longest action
  # waits MAF_STOP_TIMEOUT seconds for a run, so an older lock is from a
  # killed command or a reboot. It is taken over.
  class ControlLock
    def initialize(dir) = @dir = dir

    def hold(&block)
      take || abort("maf: another action for this worker runs. Try again later.")
      run(&block)
    end

    private

    def take
      FileUtils.mkdir_p(File.dirname(@dir))
      Dir.mkdir(@dir) && true
    rescue Errno::EEXIST
      stale? && FileUtils.rm_rf(@dir) && retry
    end

    def stale? = Time.now - File.mtime(@dir) > Integer(ENV.fetch("MAF_STOP_TIMEOUT", "1800")) + 60

    def run
      yield
    ensure
      FileUtils.rm_rf(@dir)
    end
  end
end
