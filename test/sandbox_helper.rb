# frozen_string_literal: true

# sandbox_helper.rb - shared setup for the tests of lib/maf/shared/sandbox.rb.
require_relative "harnesses/helper"
require_relative "../lib/maf/shared/sandbox"

module SandboxHelpers
  Sandbox = Maf::Shared::Sandbox
  CMD = %w[claude -p go].freeze

  def in_project(config = nil, &block)
    in_tmpdir do |dir|
      system("git", "init", "-q", dir)
      write(".maf/config.json", JSON.generate(config)) if config
      with_env("MAF_SANDBOX" => nil) { with_seatbelt(true) { block.call(dir) } }
    end
  end

  # The tests also run on Linux, where sandbox-exec is missing.
  def with_seatbelt(available)
    original = Sandbox::Seatbelt.method(:available?)
    Sandbox::Seatbelt.define_singleton_method(:available?) { available }
    yield
  ensure
    Sandbox::Seatbelt.define_singleton_method(:available?, original)
  end

  def touch_sandboxed(path) = system(*Sandbox.wrap(["touch", path], harness("claude")), err: File::NULL)
end
