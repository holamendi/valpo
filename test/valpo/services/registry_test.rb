# frozen_string_literal: true

require "test_helper"

class ValpoServicesRegistryTest < Minitest::Test
  include ValpoTestDatabase

  def test_defaults_and_supported_versions_are_definition_controlled
    project = create_project
    postgres = create_managed_service(project:, status: "provisioning", runtime: false)
    redis = create_managed_service(
      project:,
      name: "cache",
      kind: "redis",
      version: "7",
      status: "provisioning",
      runtime: false
    )

    assert_equal "18", Valpo::Services::Registry.managed_config(postgres).version
    assert_equal "postgres:18-alpine", Valpo::Services::Registry.managed_config(postgres).image
    assert_equal "7", Valpo::Services::Registry.managed_config(redis).version
    assert_equal %w[postgres redis web worker], Valpo::Services::Registry.names.sort
  end
end
