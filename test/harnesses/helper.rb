# frozen_string_literal: true

# helper.rb - shared setup for the tests of each harness in lib/maf/shared/harnesses/.
require "minitest/autorun"
require_relative "../board_guard"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../lib/maf/cli"

module HarnessTestHelpers
  # The dispatcher options that a harness reads.
  Config = Struct.new(:role, :model, :effort, :lean, :coord_dir, :skill, :no_skill, :timeout, :max_turns,
                      keyword_init: true)

  def harness(name = self.class::HARNESS) = Maf::Shared::Harness.fetch(name)
  def config(**values) = Config.new(role: "backend-developer", timeout: 300, coord_dir: "/tmp/c/coordination", **values)
  def pairs(cmd) = cmd.each_cons(2).to_a

  def with_codex_help(help, &block)
    Dir.mktmpdir do |bin|
      File.write(File.join(bin, "codex"), "#!/bin/sh\necho '#{help}'\n")
      File.chmod(0o755, File.join(bin, "codex"))
      with_env("PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}", &block)
    end
  end

  def usage(input, cached, written, output)
    { "input_tokens" => input, "cached_input_tokens" => cached, "cache_write_input_tokens" => written,
      "output_tokens" => output }
  end

  def in_tmpdir(&block) = Dir.mktmpdir { |dir| Dir.chdir(File.realpath(dir), &block) }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def with_env(values)
    old = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end
end
