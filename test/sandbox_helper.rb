# frozen_string_literal: true

# sandbox_helper.rb - shared setup for the tests of lib/maf/shared/sandbox.rb.
require_relative "harnesses/helper"
require_relative "../lib/maf/shared/sandbox"
require "socket"

module SandboxHelpers
  Sandbox = Maf::Shared::Sandbox
  CMD = %w[claude -p go].freeze

  def in_project(config = nil, &block)
    in_tmpdir do |dir|
      system("git", "init", "-q", dir)
      write(".maf/sandbox.json", JSON.generate(config["sandbox"])) if config
      with_env("MAF_SANDBOX" => nil) { with_seatbelt(true) { cleaning_tmp(dir) { block.call(dir) } } }
    end
  end

  def cleaning_tmp(dir)
    yield
  ensure
    FileUtils.rm_rf(Sandbox::Seatbelt.project_tmp(dir))
  end

  def with_bwrap(overlay:, inside: false)
    values = { available?: true, overlay?: overlay, inside?: inside, binary: "bwrap" }
    originals = values.to_h { |name, value| [name, stub_bwrap(name, value)] }
    yield
  ensure
    originals.each { |name, method| Sandbox::Bwrap.define_singleton_method(name, method) }
  end

  def stub_bwrap(name, value)
    Sandbox::Bwrap.method(name).tap { Sandbox::Bwrap.define_singleton_method(name) { value } }
  end

  def with_seatbelt(available)
    original = Sandbox::Seatbelt.method(:available?)
    Sandbox::Seatbelt.define_singleton_method(:available?) { available }
    yield
  ensure
    Sandbox::Seatbelt.define_singleton_method(:available?, original)
  end

  def native_sandbox?
    return Sandbox::Seatbelt.available? if RUBY_PLATFORM.include?("darwin")

    Sandbox::Bwrap.available? && Sandbox::Bwrap.overlay? && !Sandbox::Bwrap.inside?
  end

  def in_sandboxed_project(&block)
    in_project("sandbox" => { "mode" => "auto" }) do |dir|
      FileUtils.mkdir_p(%w[.maf/bin .maf/coordination/message-hooks])
      block.call(dir)
    end
  end

  def state_rule(home, name) = "(regex #\"^#{Sandbox::Seatbelt.escape(real_home(home))}/#{name}(/|$)\")"
  def real_home(home) = File.join(File.realpath(File.dirname(home)), File.basename(home))

  def sandboxed(script) = system(*wrapped("sh", "-c", script), out: File::NULL, err: File::NULL)
  def wrapped(*cmd) = Sandbox.wrap(cmd, harness("claude"))

  def connects?(path)
    server = UNIXServer.new(path)
    Thread.new { server.accept.close }.report_on_exception = false
    sandboxed("nc -U #{path} < /dev/null")
  ensure
    server&.close
  end

  def touch_sandboxed(path) = system(*Sandbox.wrap(["touch", path], harness("claude")), err: File::NULL)
end
