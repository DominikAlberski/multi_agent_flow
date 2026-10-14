#!/usr/bin/env ruby
# frozen_string_literal: true

# test/vm_options_test.rb - tests for the checks of maf vm create (lib/maf/vm/options.rb, lib/maf/vm/template.rb).
#
# Run: ruby test/vm_options_test.rb
require_relative "harnesses/helper"
require "yaml"

class VmOptionsTest < Minitest::Test
  include HarnessTestHelpers

  def in_project(&block)
    in_tmpdir do |dir|
      write(".maf/config.json", JSON.generate("agents" => []))
      block.call(dir)
    end
  end

  def stopped(action) = capture_io { assert_raises(SystemExit) { action.call } }.last

  def test_a_size_below_one_shows_the_usage
    in_project do |dir|
      assert_includes stopped(-> { Maf::Vm::VmOptions.parse(%w[--memory 0], dir) }), "use a number above 0"
    end
  end

  def test_the_vm_checks_the_taskwarrior_download
    in_project do |dir|
      vm = YAML.safe_load(Maf::Vm::Template.new(dir, Maf::Vm::VmOptions.parse([], dir), []).render)
      assert_includes vm["provision"].first["script"],
                      "#{Maf::Vm::Template::TASKWARRIOR_SHA256}  task.tar.gz\" | sha256sum -c -"
    end
  end
end
