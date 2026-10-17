# frozen_string_literal: true

# models_test.rb - the model lists of maf add and the interactive model choice.
require "minitest/autorun"
require_relative "board_guard"
require "stringio"
require "tmpdir"
require_relative "../lib/maf/cli"

class ModelsTest < Minitest::Test
  def test_a_harness_without_a_list_knows_every_name
    assert Maf::Flow::Models.known?("hermes", "anything")
  end

  # The menu offers only the harnesses on PATH, or all of them when none is installed.
  def test_installed_lists_registered_harnesses
    assert_empty Maf::Flow::Models.installed - Maf::Shared::Harness.names
  end
end

class MenuAddTest < Minitest::Test
  LEVELS = { "codex" => { "gpt-a" => %w[low high] },
             "claude" => { nil => %w[low high], "claude-sonnet-5-5" => %w[low high] } }.freeze

  def setup
    flows = @flows = []
    stub(Maf, :flow) { |*args| flows << args }
    stub(Maf, :role_names) { %w[architect tester] }
    stub(Maf, :role_effort) { |role| role == "tester" ? "low" : nil }
    stub_models
  end

  def stub_models
    stub(Maf::Flow::Models, :installed) { %w[claude codex] }
    stub(Maf::Flow::Models, :for) { |harness| harness == "codex" ? %w[gpt-a gpt-b] : nil }
    stub(Maf::Flow::Models, :efforts) { |harness, model| LEVELS.fetch(harness, {}).fetch(model, []) }
  end

  def teardown
    @stubs.each { |object, name, method| object.define_singleton_method(name, method) }
  end

  def stub(object, name, &block)
    (@stubs ||= []) << [object, name, object.method(name)]
    object.define_singleton_method(name, &block)
  end

  def add(input)
    out = StringIO.new
    Maf::Menu.new(Maf::Prompt.new(StringIO.new(input), out)).add
    out.string
  end

  def test_it_offers_the_installed_harnesses_and_their_models
    out = add("2\n1,2\n2\n1\n2\n")

    assert_includes out, "1) claude"
    assert_includes out, "1) gpt-a  (effort: low, high)"
    assert_equal [["--agent", "codex:architect:gpt-b", "--agent", "codex:tester:gpt-a", "--effort", "tester=high"]],
                 @flows
  end

  def test_an_unlisted_name_needs_a_confirmation
    add("2\n2\ngpt-typo\nn\ngpt-a\nultra\nn\n\n")

    assert_equal [["--agent", "codex:tester:gpt-a"]], @flows
  end

  def test_a_harness_without_a_list_takes_a_typed_name
    out = add("1\n2\nclaude-sonnet-5-5\nhigh\n")

    assert_includes out, "Enter = claude-opus-5-5"
    assert_equal [["--agent", "claude:tester:claude-sonnet-5-5", "--effort", "tester=high"]], @flows
  end

  # Enter keeps the effort of the role. maf add applies it.
  def test_enter_keeps_the_role_effort
    out = add("2\n2\n1\n\n")

    assert_includes out, "Enter = low"
    assert_equal [["--agent", "codex:tester:gpt-a"]], @flows
  end
end
