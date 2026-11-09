# frozen_string_literal: true

# budget_test.rb - the default model that maf prepare takes from the team allow list.
require "minitest/autorun"
require_relative "board_guard"
require_relative "../lib/maf/budget"

class BudgetTest < Minitest::Test
  def default_model(allow, harness) = Maf::Budget.new("allow" => allow).default_model(harness)

  def test_one_allowed_model_is_the_default
    assert_equal "gpt-6.1-sol", default_model(["codex:gpt-6.1-sol", "claude"], "codex")
  end

  # Regression: a bare harness entry gave the harness name as the model.
  def test_a_bare_harness_entry_gives_no_model
    assert_nil default_model(%w[codex claude], "codex")
  end

  def test_a_bare_entry_and_a_model_entry_give_no_model
    assert_nil default_model(["codex", "codex:gpt-6.1-sol"], "codex")
  end
end
