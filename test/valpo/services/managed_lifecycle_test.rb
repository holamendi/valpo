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

  def test_failed_provision_readiness_removes_the_started_container
    service = create_managed_service(status: "provisioning", runtime: false)
    docker = ValpoTestSupport::FakeDocker.new(fail_on: :exec)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, clock: sequence_clock(0, 2)).provision_service(
          service_id: service.id,
          queue:,
          job_id: job.id
        )
      end
    end

    container_name = service.managed_config.container_name
    assert_equal "failed", service.refresh.status
    assert docker.executed?(:stop, container_name)
    assert docker.executed?(:rm, container_name, true)
  end

  def test_provision_refuses_an_existing_network_without_the_ownership_label
    service = create_managed_service(status: "provisioning", runtime: false)
    docker = ValpoTestSupport::FakeDocker.new(network_exists: true, network_owned: false)

    error = assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:).provision_service(service_id: service.id, queue:, job_id: job.id)
      end
    end

    assert_match "exists without valpo.owned=true", error.message
    assert_empty docker.run_requests
  end

  def test_delete_requires_force_and_removes_container_volume_and_dependencies
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id, dependency_service_id: database.id, status: "active"
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

  def test_delete_restores_dependencies_and_restarted_apps_before_runtime_cleanup
    project = create_project
    first_app = create_app_service(project:, name: "first", status: "running")
    second_app = create_app_service(project:, name: "second", status: "running")
    database = create_managed_service(project:)
    dependencies = [first_app, second_app].map do
      Valpo::ServiceDependency.create(
        service_id: it.id,
        dependency_service_id: database.id,
        status: "active"
      )
    end
    dependency_manager = FailingDependencyManager.new(fail_on_call: 2)
    docker = ValpoTestSupport::FakeDocker.new

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, dependency_manager:).delete_service(
          service_id: database.id,
          force: true,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "running", database.refresh.status
    assert_equal %w[active active], dependencies.map { it.refresh.status }
    assert_equal 3, dependency_manager.service_ids.length
    assert_equal dependency_manager.service_ids.first, dependency_manager.service_ids.last
    refute docker.executed?(:stop, database.managed_config.container_name)
  end

  def test_delete_restores_active_state_when_container_stop_fails_before_volume_deletion
    project = create_project
    app = create_app_service(project:, status: "running")
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )
    docker = ValpoTestSupport::FakeDocker.new(fail_on: :stop)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, dependency_manager: FailingDependencyManager.new).delete_service(
          service_id: database.id,
          force: true,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "running", database.refresh.status
    assert_equal "active", dependency.refresh.status
  end

  def test_delete_recreates_container_when_volume_deletion_fails
    project = create_project
    app = create_app_service(project:, status: "running")
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )
    docker = ValpoTestSupport::FakeDocker.new(fail_on: :volume_rm)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, dependency_manager: FailingDependencyManager.new).delete_service(
          service_id: database.id,
          force: true,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "running", database.refresh.status
    assert_equal "active", dependency.refresh.status
    assert_equal database.managed_config.container_name, docker.run_requests.last.fetch(:name)
  end

  def test_delete_retains_failed_deleting_state_after_volume_deletion
    project = create_project
    app = create_app_service(project:, status: "running")
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )
    connection = Valpo::Database.connection
    connection.run(<<~SQL)
      CREATE TRIGGER fail_managed_service_delete
      BEFORE DELETE ON services
      WHEN OLD.id = #{connection.literal(database.id)}
      BEGIN
        SELECT RAISE(FAIL, 'injected delete failure');
      END
    SQL
    docker = ValpoTestSupport::FakeDocker.new

    assert_raises Sequel::DatabaseError do
      run_job do |queue, job|
        lifecycle(docker:, dependency_manager: FailingDependencyManager.new).delete_service(
          service_id: database.id,
          force: true,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "failed", database.refresh.status
    assert_equal "deleting", dependency.refresh.status
    assert docker.executed?(:volume_rm, database.managed_config.volume_name, true)
  ensure
    connection&.run("DROP TRIGGER IF EXISTS fail_managed_service_delete")
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

  def test_repair_checks_readiness_for_an_already_running_container
    service = create_managed_service
    docker = ValpoTestSupport::FakeDocker.new(fail_on: :exec)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, clock: sequence_clock(0, 2)).repair_services(queue:, job_id: job.id)
      end
    end

    assert_equal "failed", service.refresh.status
    assert docker.commands.any? { it.first == :exec }
  end

  private

  def run_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    yield queue, job
  end

  def lifecycle(
    docker: ValpoTestSupport::FakeDocker.new,
    dependency_manager: nil,
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  )
    Valpo::Services::ManagedLifecycle.new(
      config: VALPO_TEST_CONFIG,
      docker:,
      dependency_manager:,
      clock:
    )
  end

  def sequence_clock(*values)
    -> { values.shift || values.last }
  end

  class FailingDependencyManager
    attr_reader :service_ids

    def initialize(fail_on_call: nil)
      @fail_on_call = fail_on_call
      @service_ids = []
    end

    def restart_app_if_running(app, queue:, job_id:)
      service_ids << app.id
      raise Valpo::ValidationError, "restart failed" if service_ids.length == @fail_on_call

      true
    end
  end
end
