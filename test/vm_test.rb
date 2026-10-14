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

  def vm_name(dir) = FileUtils.mkdir_p(dir).then { Maf::Vm.new([], dir).name }

  def in_named_project(name)
    in_tmpdir do |dir|
      write(File.join(name, ".maf/config.json"), JSON.generate("agents" => []))
      Dir.chdir(File.join(dir, name)) { yield File.join(dir, name) }
    end
  end

  def test_the_name_comes_from_the_project_folder_and_its_path
    in_tmpdir do |dir|
      names = %w[a b].map { |parent| vm_name(File.join(dir, parent, "My_App.2")) }
      assert_match(/\Amaf-my-app-2-\h{8}\z/, names.first)
      refute_equal names.first, names.last
    end
  end

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

  def test_a_quote_in_the_project_path_stays_in_the_path
    in_named_project(%(project "quoted")) { |project| assert_equal project, yaml(project)["mounts"].first["location"] }
  end

  def test_the_vm_runs_the_ubuntu_with_a_new_rust
    in_project { |dir| assert_equal ["template:_images/ubuntu-26.04"], yaml(dir)["base"] }
  end

  def test_the_vm_installs_the_maf_version_of_the_host
    in_project { |dir| assert_includes template(dir).render, "gem install maf -v #{Maf::VERSION}\n" }
  end

  def test_a_local_gem_is_copied_into_the_project
    in_project do |dir|
      write("pkg/maf-9.gem", "gem")
      assert_includes template(dir, "--gem", "pkg/maf-9.gem").render, "gem install #{dir}/.maf/vm/maf-9.gem"
    end
  end

  def test_a_space_in_the_gem_path_is_escaped
    in_named_project("with space") do |project|
      write("../maf-9.gem", "gem")
      assert_includes template(project, "--gem", "../maf-9.gem").render, 'with\ space/.maf/vm'
    end
  end

  def test_a_harness_script_skips_an_installed_cli
    in_project([{ "harness" => "cursor", "role" => "a" }]) do |dir|
      script = yaml(dir)["provision"].map { |step| step["script"] }.find { |text| text.include?("cursor.com") }
      assert_operator script.index("command -v agent >/dev/null 2>&1 && exit 0"), :<, script.index("cursor.com")
    end
  end

  def test_a_missing_or_unknown_action_shows_the_usage
    in_project do |dir|
      [[], ["statsu"]].each { |argv| assert_includes stopped(-> { Maf::Vm.new(argv, dir).run }), "usage: maf vm" }
    end
  end

  def stopped(action) = capture_io { assert_raises(SystemExit) { action.call } }.last

  def test_an_unknown_flag_shows_the_usage
    in_project do |dir|
      assert_includes stopped(-> { Maf::Vm::VmOptions.parse(["--bogus"], dir) }), "invalid option: --bogus"
    end
  end
end

class VmHarnessesTest < Minitest::Test
  include HarnessTestHelpers

  def test_the_vm_finds_the_harnesses_from_a_subfolder
    in_tmpdir do |dir|
      system("git", "init", "-q", dir)
      write(".maf/config.json", JSON.generate("agents" => [{ "harness" => "codex", "role" => "tester" }]))
      Dir.chdir(FileUtils.mkdir_p("sub").first) { assert_equal ["codex"], Maf::Vm.new([], dir).send(:harnesses).map(&:name) }
    end
  end
end
