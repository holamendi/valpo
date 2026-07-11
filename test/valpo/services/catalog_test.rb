# frozen_string_literal: true

require "test_helper"
require "valpo/services/environment"

class ValpoServicesCatalogTest < Minitest::Test
  include ValpoTestDatabase

  def test_defaults_and_supported_versions_are_catalog_controlled
    project = create_project
    postgres = create_managed_service(project: project, status: "provisioning", runtime: false)
    redis = create_managed_service(project: project, name: "cache", kind: "redis", version: "7", status: "provisioning", runtime: false)

    assert_equal "18", Valpo::Services::Catalog.managed_config(postgres).version
    assert_equal "postgres:18-alpine", Valpo::Services::Catalog.managed_config(postgres).image
    assert_equal "7", Valpo::Services::Catalog.managed_config(redis).version
  end

  def test_unsupported_type_and_version_are_rejected
    project = create_project
    assert_raises(Valpo::ValidationError) do
      Valpo::Services::Catalog.create_service(project_id: project.id, name: "db", type: "mysql")
    end
    error = assert_raises(Valpo::ValidationError) do
      Valpo::Services::Catalog.create_service(project_id: project.id, name: "db", type: "postgres", version: "13")
    end
    assert_match "Unsupported postgres version", error.message
  end

  def test_dependency_env_is_scoped_and_redacted
    project = create_project
    app = create_app_service(project: project)
    database = create_managed_service(project: project)
    env = Valpo::Services::Catalog.binding_env(database)
    Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: database.id, status: "active", env_json: JSON.generate(env)
    )

    raw = Valpo::Services::Environment.raw_for_service(app.id)
    redacted = Valpo::Services::Environment.entries_for_service(app.id, reveal: false)
    assert_equal env.fetch("DATABASE_URL"), raw.fetch("DATABASE_URL")
    assert_equal "********", redacted.find { |entry| entry.fetch(:name) == "DATABASE_URL" }.fetch(:value)
    assert_equal database.managed_config.internal_host, redacted.find { |entry| entry.fetch(:name) == "PGHOST" }.fetch(:value)
  end
end
