# frozen_string_literal: true

# gemspec_test.rb - the maf gem holds every file that maf reads at runtime.
# maf copies assets/ into a project and reads templates/ and install.md. A file
# that the gem leaves out works in a clone but breaks after gem install.
require "minitest/autorun"
require_relative "board_guard"
require "rubygems"
require_relative "../lib/maf/version"

class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SPEC = Dir.chdir(ROOT) { Gem::Specification.load("maf.gemspec") }

  # A new file is in the gem only after git add.
  def test_the_gem_holds_lib_assets_and_templates
    on_disk = Dir.chdir(ROOT) { Dir.glob("{lib,assets,templates}/**/*", File::FNM_DOTMATCH).select { File.file?(_1) } }

    assert_empty on_disk - SPEC.files, "files missing from the gem (git add them)"
  end

  def test_the_gem_holds_the_guide_and_the_command
    assert_includes SPEC.files, "install.md"
    assert_includes SPEC.files, "exe/maf"
    assert_equal ["maf"], SPEC.executables
    assert File.executable?(File.join(ROOT, "exe", "maf"))
  end

  def test_the_gem_leaves_out_the_tests_and_the_docs
    assert_empty SPEC.files.grep(%r{\A(test|docs|scripts|bin)/})
  end

  def test_the_spec_version_is_the_maf_version
    assert_equal Maf::VERSION, SPEC.version.to_s
  end
end
