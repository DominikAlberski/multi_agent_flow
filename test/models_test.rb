# frozen_string_literal: true

# models_test.rb - the model lists of maf add and the interactive model choice.
require "minitest/autorun"
require_relative "board_guard"
require "stringio"
require "tmpdir"
require_relative "../lib/maf/cli"

class ModelsTest < Minitest::Test
  def test_claude_accepts_aliases_and_full_ids
    %w[opus sonnet[1m] opusplan claude-sonnet-5-5 claude-opus-5-5[1m] us.anthropic.claude-haiku-5-5-v1:0]
      .each { |name| assert Maf::Flow::Models.known?("claude", name), name }
  end

  # The typo that stopped a tester: every dispatched run failed with unrecognized_model.
  def test_claude_rejects_a_misspelled_family
    refute Maf::Flow::Models.known?("claude", "claude-sonet-5-5")
    refute Maf::Flow::Models.known?("claude", "sonet")
  end

  def test_codex_reads_the_listed_models_of_its_cache
    models = [{ slug: "gpt-a", visibility: "list" }, { slug: "gpt-x", visibility: "hide" }]
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "models_cache.json").tap { |path| File.write(path, JSON.generate(models: models)) }
      with_const(:CODEX_CACHE, cache) { assert_equal ["gpt-a"], Maf::Flow::Models.codex }
    end
  end

  def test_a_harness_without_a_list_knows_every_name
    assert Maf::Flow::Models.known?("hermes", "anything")
  end

  def with_const(name, value)
    old = Maf::Flow::Models.const_get(name)
    swap_const(name, value)
    yield
  ensure
    swap_const(name, old)
  end

  def swap_const(name, value)
    Maf::Flow::Models.send(:remove_const, name)
    Maf::Flow::Models.const_set(name, value)
  end
end

class MenuAddTest < Minitest::Test
  def setup
    flows = @flows = []
    stub(Maf, :flow) { |*args| flows << args }
    stub(Maf, :role_names) { %w[architect tester] }
    stub(Maf::Flow::Models, :installed) { %w[claude codex] }
    stub(Maf::Flow::Models, :for) { |harness| harness == "codex" ? %w[gpt-a gpt-b] : nil }
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
    out = add("2\n1,2\n2\n\n")

    assert_includes out, "1) claude"
    assert_includes out, "2) gpt-b"
    assert_equal [["--agent", "codex:architect:gpt-b", "--agent", "codex:tester"]], @flows
  end

  def test_an_unlisted_name_needs_a_confirmation
    add("2\n2\ngpt-typo\nn\ngpt-a\n")

    assert_equal [["--agent", "codex:tester:gpt-a"]], @flows
  end

  def test_a_harness_without_a_list_takes_a_typed_name
    out = add("1\n2\nclaude-sonnet-5-5\n")

    assert_includes out, "Enter = claude-opus-5-5"
    assert_equal [["--agent", "claude:tester:claude-sonnet-5-5"]], @flows
  end
end
