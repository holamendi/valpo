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

  def test_runtime_names_are_dns_safe_and_redis_secrets_stay_out_of_commands
    redis = create_managed_service(kind: "redis", runtime: false)
    runtime = Valpo::Services::Registry.runtime_attributes(redis)
    redis.managed_config.update(runtime)
    password = redis.managed_config.credentials.fetch("password")

    refute_includes runtime.fetch(:container_name), "_"
    assert_equal runtime.fetch(:container_name), runtime.fetch(:internal_host)
    assert_equal password, Valpo::Services::Registry.container_environment(redis).fetch("REDIS_PASSWORD")
    assert_equal password, Valpo::Services::Registry.container_environment(redis).fetch("REDISCLI_AUTH")
    refute_includes Valpo::Services::Registry.command(redis).join(" "), password
    refute_includes Valpo::Services::Registry.readiness_command(redis).join(" "), password
  end

  def test_postgres_volume_path_targets_the_version_specific_data_directory
    project = create_project
    expected = {
      "16" => "/var/lib/postgresql/data",
      "17" => "/var/lib/postgresql/data",
      "18" => "/var/lib/postgresql"
    }

    expected.each do |version, path|
      service = create_managed_service(project:, name: "database-#{version}", version:)
      assert_equal path, Valpo::Services::Registry.volume_path(service)
    end
  end
end
