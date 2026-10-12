#!/usr/bin/env ruby
# frozen_string_literal: true

# test/vm_test.rb - tests for maf vm (lib/maf/vm.rb).
#
# Run: ruby test/vm_test.rb
require_relative "harnesses/helper"
require "yaml"

class VmTest < Minitest::Test
  include HarnessTestHelpers

  def in_project(agents = [])
    in_tmpdir do |dir|
      write(".maf/config.json", JSON.generate("agents" => agents))
      yield dir
    end
  end

  def harnesses = Maf.agents.map { |agent| Maf::Shared::Harness.fetch(agent["harness"]) }.uniq
  def template(dir, *args) = Maf::Vm::Template.new(dir, Maf::Vm::VmOptions.parse(args, dir), harnesses)
  def yaml(dir, *args) = YAML.safe_load(template(dir, *args).render)

  def test_the_name_comes_from_the_project_folder
    assert_equal "maf-my-app-2", Maf::Vm.new([], "/x/My_App.2").name
  end

  # The worktrees and the taskrc hold absolute paths, so the VM mounts the project at the same path.
  def test_the_vm_mounts_only_the_project_at_its_host_path
    in_project { |dir| assert_equal [{ "location" => dir, "writable" => true }], yaml(dir)["mounts"] }
  end

  def test_flags_set_the_size
    in_project do |dir|
      vm = yaml(dir, "--cpus", "2", "--memory", "4", "--disk", "20")
      assert_equal [2, "4GiB", "20GiB"], vm.values_at("cpus", "memory", "disk")
    end
  end

  def test_the_vm_installs_the_cli_of_each_harness_of_the_project
    in_project([{ "harness" => "claude", "role" => "a" }, { "harness" => "claude", "role" => "b" }]) do |dir|
      scripts = yaml(dir)["provision"].map { |step| step["script"] }
      assert_equal(1, scripts.count { |script| script.include?("claude.ai/install.sh") })
      refute(scripts.any? { |script| script.include?("@openai/codex") })
    end
  end

  def test_a_harness_without_an_install_command_gets_a_note
    in_project([{ "harness" => "hermes", "role" => "a" }]) do |dir|
      assert_includes template(dir).notes, "Install hermes in the VM yourself."
    end
  end

  def rendered_for(dir, os)
    vm = template(dir).tap { |t| t.define_singleton_method(:host) { os } }
    YAML.safe_load(vm.render)
  end

  def test_the_vm_type_follows_the_host_os
    in_project do |dir|
      { "darwin" => %w[vz virtiofs], "linux" => %w[qemu 9p] }.each do |os, types|
        assert_equal types, rendered_for(dir, os).values_at("vmType", "mountType")
      end
    end
  end

  # The VM sees only the project, so a local gem goes into the project.
  def test_a_local_gem_is_copied_into_the_project
    in_project do |dir|
      write("pkg/maf-9.gem", "gem")
      assert_includes template(dir, "--gem", "pkg/maf-9.gem").render, "gem install #{dir}/.maf/vm/maf-9.gem"
    end
  end
end
