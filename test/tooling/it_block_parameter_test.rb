# frozen_string_literal: true

require "test_helper"
require "rubocop"
require_relative "../../tools/rubocop/cop/valpo/it_block_parameter"

class ValpoItBlockParameterCopTest < Minitest::Test
  def test_requires_it_for_references_in_the_same_block_scope
    offenses = investigate("items.map { |item| item.name }")

    assert_equal 1, offenses.length
    assert_equal "Use `it` when the block parameter stays within this block scope.", offenses.first.message
  end

  def test_keeps_a_named_parameter_when_a_nested_block_references_it
    offenses = investigate("items.map { |item| nested.map { use(item) } }")

    assert_empty offenses
  end

  private

  def investigate(source)
    config = RuboCop::Config.new("Valpo/ItBlockParameter" => {"Enabled" => true})
    cop = RuboCop::Cop::Valpo::ItBlockParameter.new(config)
    team = RuboCop::Cop::Team.new([cop], config)
    team.investigate(RuboCop::ProcessedSource.new(source, 4.0)).offenses
  end
end
