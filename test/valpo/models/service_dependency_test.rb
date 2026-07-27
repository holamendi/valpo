# frozen_string_literal: true

require "test_helper"

class ValpoServiceDependencyTest < Minitest::Test
  include ValpoTestDatabase

  def test_dependency_exposes_env_and_validates_status
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )

    assert_equal database.id, dependency.dependency_service_id
    assert_match(/\Adep_[0-9a-f]{32}\z/, dependency.id)
    assert_raises(Sequel::ValidationFailed) { dependency.update(status: "unknown") }
  end

  def test_dependency_rejects_cross_project_and_non_managed_targets
    project = create_project
    app = create_app_service(project:)
    worker = create_app_service(project:, name: "worker", kind: "worker")
    error = assert_raises(Sequel::ValidationFailed) do
      Valpo::ServiceDependency.create(service_id: app.id, dependency_service_id: worker.id)
    end
    assert_match "managed service", error.message

    other = create_project(name: "other")
    database = create_managed_service(project: other)
    error = assert_raises(Sequel::ValidationFailed) do
      Valpo::ServiceDependency.create(service_id: app.id, dependency_service_id: database.id)
    end
    assert_match "same project", error.message
  end
end
