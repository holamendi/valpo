# frozen_string_literal: true

require "test_helper"

class ValpoServicesDependencyManagerTest < Minitest::Test
  include ValpoTestDatabase

  def test_bind_scopes_env_to_app_and_restarts_running_app
    project = create_project
    app = create_app_service(project:, status: "running")
    create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    database = create_managed_service(project:)
    deployment = FakeDeploymentLifecycle.new

    dependency = run_job do |queue, job|
      manager(deployment_lifecycle: deployment).bind_service(
        service_id: app.id, dependency_service_id: database.id, queue:, job_id: job.id
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
      run_job { |queue, job| manager.bind_service(service_id: app.id, dependency_service_id: other_database.id, queue:, job_id: job.id) }
    end

    first = create_managed_service(project: first_project)
    second = create_managed_service(project: first_project, name: "other-db")
    Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: first.id, status: "active",
      env_json: JSON.generate(Valpo::Services::Registry.binding_environment(first))
    )
    assert_raises(Valpo::ConflictError) do
      run_job { |queue, job| manager.bind_service(service_id: app.id, dependency_service_id: second.id, queue:, job_id: job.id) }
    end
  end

  def test_failed_bind_restart_removes_a_new_dependency
    project = create_project
    app = create_app_service(project:, status: "running")
    create_release(service: app, status: "active")
    database = create_managed_service(project:)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        manager(deployment_lifecycle: FakeDeploymentLifecycle.new(error: "restart failed")).bind_service(
          service_id: app.id,
          dependency_service_id: database.id,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_nil Valpo::ServiceDependency.where(
      service_id: app.id,
      dependency_service_id: database.id
    ).first
  end

  def test_failed_rebind_restores_the_previous_dependency
    project = create_project
    app = create_app_service(project:, status: "running")
    create_release(service: app, status: "active")
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "deleting",
      env_json: JSON.generate("OLD_URL" => "old")
    )

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        manager(deployment_lifecycle: FakeDeploymentLifecycle.new(error: "restart failed")).bind_service(
          service_id: app.id,
          dependency_service_id: database.id,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "deleting", dependency.refresh.status
    assert_equal({"OLD_URL" => "old"}, dependency.env)
  end

  def test_unbind_removes_dependency
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: database.id, status: "active", env_json: "{}"
    )
    run_job { |queue, job| manager.unbind_service(service_id: app.id, dependency_service_id: database.id, queue:, job_id: job.id) }
    assert_nil Valpo::ServiceDependency[dependency.id]
  end

  private

  def run_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    yield queue, job
  end

  def manager(deployment_lifecycle: FakeDeploymentLifecycle.new)
    Valpo::Services::DependencyManager.new(
      config: VALPO_TEST_CONFIG,
      docker: ValpoTestSupport::FakeDocker.new,
      deployment_lifecycle:
    )
  end

  class FakeDeploymentLifecycle
    attr_reader :service_id

    def initialize(error: nil)
      @error = error
    end

    def restart_service(service_id:, queue:, job_id:)
      @service_id = service_id
      raise Valpo::ValidationError, @error if @error

      queue.event(job_id, "system", "fake restart")
    end
  end
end
