# frozen_string_literal: true

require "test_helper"
require "valpo/services/orchestrator"

class ValpoServicesOrchestratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_provision_postgres_runs_private_persistent_container
    service = create_managed_service(status: "provisioning", runtime: false)
    docker = ValpoTestSupport::FakeDocker.new
    run_job { |queue, job| orchestrator(docker: docker).provision_service(service_id: service.id, queue: queue, job_id: job.id) }
    managed = service.managed_config.refresh

    assert_equal "running", service.refresh.status
    assert docker.executed?(:volume_create, managed.volume_name)
    request = docker.run_requests.first
    assert_equal "postgres:18-alpine", request.fetch(:image)
    assert_equal({}, request.fetch(:ports))
    assert_equal({managed.volume_name => "/var/lib/postgresql"}, request.fetch(:volumes))
    assert_equal service.project_id, request.fetch(:labels).fetch("valpo.project_id")
  end

  def test_bind_scopes_env_to_app_and_restarts_running_app
    project = create_project
    app = create_app_service(project: project, status: "running")
    create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    database = create_managed_service(project: project)
    deployment = FakeDeploymentOrchestrator.new

    dependency = run_job do |queue, job|
      orchestrator(deployment_orchestrator: deployment).bind_service(
        service_id: app.id, dependency_service_id: database.id, queue: queue, job_id: job.id
      )
    end

    assert_equal "active", dependency.status
    assert_equal app.id, deployment.service_id
    assert dependency.env.key?("DATABASE_URL")
  end

  def test_bind_rejects_cross_project_and_duplicate_env_keys
    first_project = create_project
    app = create_app_service(project: first_project)
    other_project = create_project(name: "other")
    other_database = create_managed_service(project: other_project)
    assert_raises(Valpo::ValidationError) do
      run_job { |queue, job| orchestrator.bind_service(service_id: app.id, dependency_service_id: other_database.id, queue: queue, job_id: job.id) }
    end

    first = create_managed_service(project: first_project)
    second = create_managed_service(project: first_project, name: "other-db")
    Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: first.id, status: "active",
      env_json: JSON.generate(Valpo::Services::Catalog.binding_env(first))
    )
    assert_raises(Valpo::ConflictError) do
      run_job { |queue, job| orchestrator.bind_service(service_id: app.id, dependency_service_id: second.id, queue: queue, job_id: job.id) }
    end
  end

  def test_unbind_removes_dependency
    project = create_project
    app = create_app_service(project: project)
    database = create_managed_service(project: project)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: database.id, status: "active", env_json: "{}"
    )
    run_job { |queue, job| orchestrator.unbind_service(service_id: app.id, dependency_service_id: database.id, queue: queue, job_id: job.id) }
    assert_nil Valpo::ServiceDependency[dependency.id]
  end

  def test_delete_requires_force_and_removes_container_volume_and_dependencies
    project = create_project
    app = create_app_service(project: project)
    database = create_managed_service(project: project)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: database.id, status: "active", env_json: "{}"
    )
    docker = ValpoTestSupport::FakeDocker.new
    assert_raises(Valpo::ValidationError) do
      run_job { |queue, job| orchestrator(docker: docker).delete_service(service_id: database.id, force: false, queue: queue, job_id: job.id) }
    end
    managed = database.managed_config
    run_job { |queue, job| orchestrator(docker: docker).delete_service(service_id: database.id, force: true, queue: queue, job_id: job.id) }
    assert_nil Valpo::Service[database.id]
    assert_nil Valpo::ServiceDependency[dependency.id]
    assert docker.executed?(:volume_rm, managed.volume_name, true)
  end

  def test_repair_restarts_stopped_and_recreates_missing_managed_containers
    project = create_project
    stopped = create_managed_service(project: project)
    missing = create_managed_service(project: project, name: "cache", kind: "redis")
    docker = ValpoTestSupport::FakeDocker.new(container_states: {
      stopped.managed_config.container_name => false,
      missing.managed_config.container_name => :missing
    })
    run_job { |queue, job| orchestrator(docker: docker).repair_services(queue: queue, job_id: job.id) }
    assert docker.executed?(:start, stopped.managed_config.container_name)
    assert docker.run_requests.any? { |request| request.fetch(:name) == missing.managed_config.container_name }
  end

  private

  def run_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")
    yield queue, job
  end

  def orchestrator(docker: ValpoTestSupport::FakeDocker.new, deployment_orchestrator: FakeDeploymentOrchestrator.new)
    Valpo::Services::Orchestrator.new(
      config: VALPO_TEST_CONFIG, docker: docker, deployment_orchestrator: deployment_orchestrator
    )
  end

  class FakeDeploymentOrchestrator
    attr_reader :service_id

    def restart_service(service_id:, queue:, job_id:)
      @service_id = service_id
      queue.event(job_id, "system", "fake restart")
    end
  end
end
