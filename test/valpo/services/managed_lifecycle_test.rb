# frozen_string_literal: true

require "test_helper"

class ValpoServicesManagedLifecycleTest < Minitest::Test
  include ValpoTestDatabase

  def test_provision_postgres_runs_private_persistent_container
    service = create_managed_service(status: "provisioning", runtime: false)
    docker = ValpoTestSupport::FakeDocker.new
    run_job { |queue, job| lifecycle(docker:).provision_service(service_id: service.id, queue:, job_id: job.id) }
    managed = service.managed_config.refresh

    assert_equal "running", service.refresh.status
    assert docker.executed?(:volume_create, managed.volume_name)
    request = docker.run_requests.first
    assert_equal "postgres:18-alpine", request.fetch(:image)
    assert_equal({}, request.fetch(:ports))
    assert_equal({managed.volume_name => "/var/lib/postgresql"}, request.fetch(:volumes))
    assert_equal service.project_id, request.fetch(:labels).fetch("valpo.project_id")
  end

  def test_delete_requires_force_and_removes_container_volume_and_dependencies
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: database.id, status: "active", env_json: "{}"
    )
    docker = ValpoTestSupport::FakeDocker.new
    assert_raises(Valpo::ValidationError) do
      run_job { |queue, job| lifecycle(docker:).delete_service(service_id: database.id, force: false, queue:, job_id: job.id) }
    end
    managed = database.managed_config
    run_job { |queue, job| lifecycle(docker:).delete_service(service_id: database.id, force: true, queue:, job_id: job.id) }
    assert_nil Valpo::Service[database.id]
    assert_nil Valpo::ServiceDependency[dependency.id]
    assert docker.executed?(:volume_rm, managed.volume_name, true)
  end

  def test_repair_restarts_stopped_and_recreates_missing_managed_containers
    project = create_project
    stopped = create_managed_service(project:)
    missing = create_managed_service(project:, name: "cache", kind: "redis")
    docker = ValpoTestSupport::FakeDocker.new(container_states: {
      stopped.managed_config.container_name => false,
      missing.managed_config.container_name => :missing
    })
    run_job { |queue, job| lifecycle(docker:).repair_services(queue:, job_id: job.id) }
    assert docker.executed?(:start, stopped.managed_config.container_name)
    assert docker.run_requests.any? { it.fetch(:name) == missing.managed_config.container_name }
  end

  private

  def run_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")
    yield queue, job
  end

  def lifecycle(docker: ValpoTestSupport::FakeDocker.new)
    Valpo::Services::ManagedLifecycle.new(config: VALPO_TEST_CONFIG, docker:)
  end
end
