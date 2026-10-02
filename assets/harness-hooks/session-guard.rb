# frozen_string_literal: true

# session-guard.rb - authorize hooks for a registered MAF session.
require "json"
require "fileutils"
require "securerandom"

module MafSession
  def self.register(root, harness, env = ENV)
    token = SecureRandom.hex(32)
    record = registration(root, harness, env)
    save(record, token)
    env.merge!("MAF_SESSION_TOKEN" => token, "COORD_SESSION_PID" => Process.pid.to_s)
  end

  def self.registration(root, harness, env)
    { "root" => File.realpath(root), "dir" => File.realpath(Dir.pwd), "pid" => Process.pid,
      "harness" => harness, "role" => env.fetch("COORD_ROLE"), "worker" => env.fetch("COORD_WORKER") }
  end

  def self.path(root, token)
    File.join(root, ".maf", "coordination", "sessions", "#{token}.maf.json")
  end

  def self.save(record, token)
    path = path(record.fetch("root"), token)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(record), mode: "w", perm: 0o600)
  end

  # Process ownership prevents sibling sessions from using inherited tokens.
  module ProcessOwner
    def self.ancestor?(owner)
      return true if [Process.pid, Process.ppid].include?(owner)

      includes?(Process.ppid, owner, parents)
    rescue SystemCallError
      false
    end

    def self.parents
      IO.popen(%w[ps -eo pid=,ppid=], err: File::NULL, &:read)
        .lines.to_h { |line| line.split.map(&:to_i) }
    end

    def self.includes?(pid, owner, parents)
      return true if pid == owner
      return false if pid <= 1 || !parents.key?(pid)

      includes?(parents.fetch(pid), owner, parents)
    end
  end

  class Guard
    attr_reader :coord_dir, :taskrc, :coord

    def initialize(env, input = {})
      @env, @input = env, input.is_a?(Hash) ? input : {}
      @record = record
      @coord_dir = @record && File.join(@record.fetch("root"), ".maf", "coordination")
      @taskrc = @coord_dir && File.join(@coord_dir, "taskrc")
      @coord = @coord_dir && File.join(@coord_dir, "..", "bin", "coord")
    end

    def authorized?
      @record && identity? && location? && board? && ProcessOwner.ancestor?(@record.fetch("pid")) && session?
    rescue SystemCallError, KeyError, TypeError, ArgumentError
      false
    end

    private

    def record
      return unless @env["MAF_SESSION_TOKEN"].to_s.match?(/\A[0-9a-f]{64}\z/)

      data = JSON.parse(File.read(record_path))
      data if valid_record?(data)
    rescue SystemCallError, JSON::ParserError, TypeError
      nil
    end

    def record_path
      File.join(@env.fetch("COORD_DIR", ""), "sessions", "#{@env['MAF_SESSION_TOKEN']}.maf.json")
    end

    def valid_record?(data)
      data.is_a?(Hash) && %w[root dir role worker harness].all? { |key| data[key].is_a?(String) } &&
        data["pid"].is_a?(Integer) && data["pid"].positive?
    end

    def identity?
      @record.fetch("role") == @env["COORD_ROLE"] && @record.fetch("worker") == @env["COORD_WORKER"] &&
        @record.fetch("pid").to_s == @env["COORD_SESSION_PID"]
    end

    def location?
      dir = File.realpath(@record.fetch("dir"))
      current = File.realpath(@input.fetch("cwd", Dir.pwd))
      current == dir || current.start_with?("#{dir}/")
    end

    def board?
      File.realpath(@env.fetch("COORD_DIR")) == File.realpath(@coord_dir) &&
        File.realpath(@env.fetch("TASKRC")) == File.realpath(@taskrc) && File.executable?(@coord)
    end

    def session?
      id = @input["session_id"].to_s
      return false if id.empty?

      @input["hook_event_name"] == "SessionStart" ? bind(id) : bound?(id)
    end

    # A new harness session (/clear, a new Codex or opencode session) replaces
    # the bound ID. Process ownership already rejects sibling processes.
    # A temp file per process and a rename keep parallel SessionStart hooks safe.
    def bind(id)
      temp = "#{record_path}.session.#{Process.pid}"
      File.write(temp, id, perm: 0o600)
      File.rename(temp, "#{record_path}.session")
      true
    end

    def bound?(id)
      File.read("#{record_path}.session") == id
    end
  end
end
