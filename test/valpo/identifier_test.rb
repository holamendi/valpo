# frozen_string_literal: true

require "test_helper"

class ValpoIdentifierTest < Minitest::Test
  def test_generates_typed_uuid_v7_identifiers
    first = Valpo::Identifier.generate(:service)
    second = Valpo::Identifier.generate(:service)
    assert_match(/\Asvc_[0-9a-f]{32}\z/, first)
    assert Valpo::Identifier.valid?(first, :service)
    refute_equal first, second
    refute Valpo::Identifier.valid?(first, :project)
  end
end
