# frozen_string_literal: true

require "test_helper"

class ValpoServicesEnvironmentManagerTest < Minitest::Test
  include ValpoTestDatabase

  def test_stores_encrypted_service_values_and_rejects_managed_names
    project = create_project
    app = create_app_service(project:)
    manager = Valpo::Services::EnvironmentManager.new
    variable = manager.set(service_id: app.id, name: "API_KEY", value: "secret-value")

    assert_equal "secret-value", variable.value
    refute_includes variable.value_ciphertext, "secret-value"
    assert_equal 1, app.refresh.environment_revision
    assert_equal "secret-value", Valpo::Services::Environment.raw_for_service(app.id).fetch("API_KEY")
    entry = Valpo::Services::Environment.entries_for_service(app.id, reveal: false).first
    assert_equal "********", entry.fetch(:value)
    assert_equal "service", entry.fetch(:origin)

    assert_raises(Valpo::ConflictError) do
      manager.set(service_id: app.id, name: "PORT", value: "4000")
    end

    database = create_managed_service(project:)
    Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )
    assert_raises(Valpo::ConflictError) do
      manager.set(service_id: app.id, name: "DATABASE_URL", value: "custom")
    end
  end

  def test_reconciles_only_stale_running_releases
    app = create_app_service(status: "running")
    release = create_release(service: app, status: "active", environment_revision: 0)
    deployment = FakeDeployment.new
    manager = Valpo::Services::EnvironmentManager.new(deployment_lifecycle: deployment)
    manager.set(service_id: app.id, name: "FEATURE_ENABLED", value: "true", sensitive: false)
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")

    manager.reconcile(service_id: app.id, queue:, job_id: job.id)

    assert_equal app.id, deployment.service_id
    assert_equal app.refresh.environment_revision, release.refresh.environment_revision
    deployment.service_id = nil
    manager.reconcile(service_id: app.id, queue:, job_id: job.id)
    assert_nil deployment.service_id
  end

  class FakeDeployment
    attr_accessor :service_id

    def restart_service(service_id:, **)
      self.service_id = service_id
    end
  end
end
