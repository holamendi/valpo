# frozen_string_literal: true

require "test_helper"

class ValpoServicesEnvironmentTest < Minitest::Test
  include ValpoTestDatabase

  def test_dependency_environment_is_scoped_and_redacted
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    env = Valpo::Services::Registry.binding_environment(database)
    Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )

    raw = Valpo::Services::Environment.raw_for_service(app.id)
    redacted = Valpo::Services::Environment.entries_for_service(app.id, reveal: false)
    assert_equal env.fetch("DATABASE_URL"), raw.fetch("DATABASE_URL")
    assert_equal "********", redacted.find { it.fetch(:name) == "DATABASE_URL" }.fetch(:value)
    assert_equal database.managed_config.internal_host,
      redacted.find { it.fetch(:name) == "PGHOST" }.fetch(:value)
  end
end
