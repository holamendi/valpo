# frozen_string_literal: true

require "test_helper"

class ValpoLoaderTest < Minitest::Test
  include ValpoTestDatabase

  def test_all_valpo_constants_follow_zeitwerk_conventions
    Valpo.loader.eager_load

    assert defined?(Valpo::API::App)
    assert defined?(Valpo::CLI)
    assert defined?(Valpo::Project)
    assert defined?(Valpo::Services::Orchestrator)
  end
end
