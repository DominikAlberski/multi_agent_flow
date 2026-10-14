#!/usr/bin/env ruby
# frozen_string_literal: true

# test/sandbox_bwrap_helpers_test.rb - tests for the helpers in lib/maf/shared/sandbox/bwrap.rb
# that need no bubblewrap: the check for a run inside the sandbox, and the masked paths.
#
# Run: ruby test/sandbox_bwrap_helpers_test.rb
require_relative "sandbox_helper"

class SandboxBwrapHelpersTest < Minitest::Test
  include HarnessTestHelpers
  include SandboxHelpers

  def test_the_overlay_of_a_home_folder_with_a_space_is_found
    with_env("HOME" => "/home/John Doe") do
      assert Sandbox::Bwrap.home_overlay?("36 35 0:5 / /home/John\\040Doe rw - overlay overlay rw")
    end
  end

  def test_a_run_needs_the_marker_and_the_overlay_to_be_inside
    Tempfile.create do |file|
      file.write("1 2 0:5 / #{Dir.home} rw - overlay o rw\n") && file.flush
      marks = [nil, "1"].map { |mark| with_env(Sandbox::Bwrap::MARKER => mark) { Sandbox::Bwrap.inside?(file.path) } }
      assert_equal [false, true], marks
    end
  end

  def test_bwrap_is_not_taken_from_a_folder_that_the_agent_can_write
    in_tmpdir do |dir|
      write("bin/bwrap", "") && File.chmod(0o755, "bin/bwrap")
      with_env("PATH" => "#{dir}/bin:/usr/bin:/bin") { refute_equal "#{dir}/bin/bwrap", Sandbox::Bwrap.binary }
    end
  end

  def test_bwrap_is_not_taken_from_a_folder_of_the_write_list
    in_project("sandbox" => { "mode" => "bwrap", "write" => ["/opt/maf-tools"] }) do
      assert_equal([true, false], ["/opt/maf-tools", "/opt/other"].map { |dir| Sandbox::Bwrap.agent_dir?(dir) })
    end
  end

  def test_maf_does_not_create_a_placeholder_that_breaks_a_harness
    names = %w[codex cursor].flat_map { |name| Maf::Shared::Harness[name].sandbox_placeholders }
    refute_empty names
    assert_empty names.grep(%r{/(packages|cli-config\.json)\z})
  end

  def test_a_parent_in_the_private_tmp_or_a_masked_folder_is_not_bound
    paths = Struct.new(:dirs, :harness_dirs, :prefixes, :parents)
                  .new(["/srv/project", "/tmp", "/run/user/1000/tmp"], [], [], PARENTS)
    assert_equal ["/srv/project", "/srv/project/.maf"], Sandbox::Bwrap.bound_parents(paths)
  end

  PARENTS = ["/tmp", "/tmp/hooks", "/run/user/1000/tmp", "/srv/project", "/srv/project/.maf"].freeze

  def test_a_path_in_or_above_a_masked_folder_stays_masked
    marks = ["/run/user/1000/tmp", "/run", "/run/docker.sock", "/srv/tmp"].map { |path| Sandbox::Bwrap.masked?(path) }
    assert_equal [true, true, true, false], marks
  end
end
