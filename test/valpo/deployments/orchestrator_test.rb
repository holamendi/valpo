# frozen_string_literal: true

require "test_helper"
require "valpo/deployments/orchestrator"

class ValpoDeploymentsOrchestratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_successful_deploy_activates_release_and_routes_domains
    project = Valpo::Project.create(name: "hello")
    domain = Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com")
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    release = orchestrator(docker: docker, caddy: caddy).deploy_registry_image(
      project_id: project.id,
      image: "ghcr.io/example/hello:latest",
      internal_port: 3000,
      healthcheck_path: "/health",
      queue: queue,
      job_id: job.id
    )

    assert_equal "active", release.status
    assert_equal "running", project.refresh.status
    assert_equal "ghcr.io/example/hello:latest@sha256:abc", release.image_digest
    assert_equal "127.0.0.1:20000", release.route_target
    assert_equal "127.0.0.1:20000", domain.refresh.route_target
    assert_equal [{hostname: "hello.example.com", kind: "container", upstream: "127.0.0.1:20000"}], caddy.routes

    run_request = docker.run_requests.first
    assert_equal({"127.0.0.1:20000" => 3000}, run_request.fetch(:ports))
    assert_equal "unless-stopped", run_request.fetch(:restart_policy)
  end

  def test_failed_deploy_keeps_existing_active_release
    project = Valpo::Project.create(name: "hello", status: "running")
    active = Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v1",
      status: "active",
      internal_port: 3000,
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    domain = Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com", route_target: "127.0.0.1:20000")
    docker = ValpoTestSupport::FakeDocker.new(fail_on: :run)
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    assert_raises Valpo::ValidationError do
      orchestrator(docker: docker, caddy: caddy).deploy_registry_image(
        project_id: project.id,
        image: "ghcr.io/example/hello:v2",
        internal_port: 3000,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal "active", active.refresh.status
    assert_equal "running", project.refresh.status
    assert_equal "127.0.0.1:20000", domain.refresh.route_target
    assert_nil caddy.routes
    assert_equal "failed", Valpo::Release.where(project_id: project.id, version: 2).first.status
  end

  def test_rollback_reactivates_previous_release
    project = Valpo::Project.create(name: "hello", status: "running")
    previous = Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v1",
      artifact_ref: "ghcr.io/example/hello:v1@sha256:old",
      status: "inactive",
      internal_port: 3000,
      container_name: "previous",
      route_target: "127.0.0.1:20000"
    )
    current = Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v2",
      artifact_ref: "ghcr.io/example/hello:v2@sha256:new",
      status: "active",
      internal_port: 3000,
      container_name: "current",
      route_target: "127.0.0.1:20001"
    )
    Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com")
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    rolled_back = orchestrator(docker: docker, caddy: caddy).rollback_project(project_id: project.id, queue: queue, job_id: job.id)

    assert_equal previous.id, rolled_back.id
    assert_equal "active", previous.refresh.status
    assert_equal "inactive", current.refresh.status
    assert_equal "127.0.0.1:20000", previous.refresh.route_target
    assert docker.executed?(:stop, "current")
  end

  def test_stop_and_restart_project_update_caddy_routes
    project = Valpo::Project.create(name: "hello", status: "running")
    release = Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v1",
      artifact_ref: "ghcr.io/example/hello:v1@sha256:old",
      status: "active",
      internal_port: 3000,
      container_name: "active",
      route_target: "127.0.0.1:20000"
    )
    domain = Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com", route_target: "127.0.0.1:20000")
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")
    service = orchestrator(docker: docker, caddy: caddy)

    service.stop_project(project_id: project.id, queue: queue, job_id: job.id)

    assert_equal "stopped", project.refresh.status
    assert_nil domain.refresh.route_target
    assert_empty caddy.routes

    service.restart_project(project_id: project.id, queue: queue, job_id: job.id)

    assert_equal "running", project.refresh.status
    assert_equal "127.0.0.1:20000", release.refresh.route_target
    refute_empty caddy.routes
  end

  def test_app_logs_read_active_container_logs
    project = Valpo::Project.create(name: "hello")
    Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v1",
      status: "active",
      container_name: "active",
      internal_port: 3000
    )

    logs = orchestrator(docker: ValpoTestSupport::FakeDocker.new).app_logs(project_id: project.id, tail: 10)

    assert_equal "app log\n", logs.fetch(:stdout)
  end

  def test_delete_project_removes_routes_containers_and_records
    project = Valpo::Project.create(name: "hello", status: "running")
    Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v1",
      status: "active",
      internal_port: 3000,
      container_name: "active",
      route_target: "127.0.0.1:20000"
    )
    Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v0",
      status: "inactive",
      internal_port: 3000,
      container_name: "old",
      route_target: "127.0.0.1:20001"
    )
    Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com", route_target: "127.0.0.1:20000")
    other = Valpo::Project.create(name: "other", status: "running")
    Valpo::Release.create(
      project_id: other.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/other:v1",
      status: "active",
      internal_port: 3000,
      container_name: "other-active",
      route_target: "127.0.0.1:20050"
    )
    Valpo::Domain.create(project_id: other.id, hostname: "other.example.com", route_target: "127.0.0.1:20050")
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    orchestrator(docker: docker, caddy: caddy).delete_project(project_id: project.id, queue: queue, job_id: job.id)

    assert_nil Valpo::Project[project.id]
    assert_empty Valpo::Release.where(project_id: project.id).all
    assert_empty Valpo::Domain.where(project_id: project.id).all
    assert_equal [{hostname: "other.example.com", kind: "container", upstream: "127.0.0.1:20050"}], caddy.routes
    assert docker.executed?(:stop, "active")
    assert docker.executed?(:rm, "active", true)
    assert docker.executed?(:stop, "old")
    assert docker.executed?(:rm, "old", true)
    assert_includes queue.events(job.id).map(&:message), "Deleted hello"
  end

  def test_repair_system_regenerates_caddy_routes_from_database_state
    project = Valpo::Project.create(name: "hello", status: "running")
    Valpo::Release.create(
      project_id: project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/hello:v1",
      status: "active",
      internal_port: 3000,
      container_name: "active",
      route_target: "127.0.0.1:20000"
    )
    domain = Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com", route_target: nil)
    stopped = Valpo::Project.create(name: "stopped", status: "stopped")
    Valpo::Release.create(
      project_id: stopped.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/stopped:v1",
      status: "active",
      internal_port: 3000,
      container_name: "stopped-active",
      route_target: "127.0.0.1:20001"
    )
    stopped_domain = Valpo::Domain.create(project_id: stopped.id, hostname: "stopped.example.com", route_target: "127.0.0.1:20001")
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    orchestrator(docker: ValpoTestSupport::FakeDocker.new, caddy: caddy).repair_system(queue: queue, job_id: job.id)

    assert_equal [{hostname: "hello.example.com", kind: "container", upstream: "127.0.0.1:20000"}], caddy.routes
    assert_equal "127.0.0.1:20000", domain.refresh.route_target
    assert_nil stopped_domain.refresh.route_target
    assert_includes queue.events(job.id).map(&:message), "Repairing system state"
  end

  def test_repair_system_restarts_stopped_containers_and_recreates_missing_containers
    stopped_project = Valpo::Project.create(name: "stopped-runtime", status: "failed")
    stopped_release = Valpo::Release.create(
      project_id: stopped_project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/stopped-runtime:v1",
      artifact_ref: "ghcr.io/example/stopped-runtime:v1@sha256:old",
      status: "active",
      internal_port: 3000,
      healthcheck_path: "/health",
      container_name: "stopped-runtime-container",
      route_target: "127.0.0.1:20000"
    )
    missing_project = Valpo::Project.create(name: "missing-runtime", status: "running")
    missing_release = Valpo::Release.create(
      project_id: missing_project.id,
      source_type: "registry",
      source_ref: "ghcr.io/example/missing-runtime:v1",
      artifact_ref: "ghcr.io/example/missing-runtime:v1@sha256:old",
      status: "active",
      internal_port: 3000,
      healthcheck_path: "/health",
      container_name: "missing-runtime-container",
      route_target: "127.0.0.1:20001"
    )
    Valpo::Domain.create(project_id: stopped_project.id, hostname: "stopped-runtime.example.com")
    Valpo::Domain.create(project_id: missing_project.id, hostname: "missing-runtime.example.com")
    docker = ValpoTestSupport::FakeDocker.new(container_states: {
      "stopped-runtime-container" => false,
      "missing-runtime-container" => :missing
    })
    caddy = ValpoTestSupport::FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    orchestrator(docker: docker, caddy: caddy).repair_system(queue: queue, job_id: job.id)

    assert docker.executed?(:update_restart_policy, "stopped-runtime-container", "unless-stopped")
    assert docker.executed?(:start, "stopped-runtime-container")
    assert_equal "running", stopped_project.refresh.status
    assert_equal "stopped-runtime-container", stopped_release.refresh.container_name

    run_request = docker.run_requests.find { |request| request.fetch(:image) == "ghcr.io/example/missing-runtime:v1@sha256:old" }
    refute_nil run_request
    assert_equal "unless-stopped", run_request.fetch(:restart_policy)
    assert_equal "running", missing_project.refresh.status
    refute_equal "missing-runtime-container", missing_release.refresh.container_name
    assert caddy.routes.any? { |route| route.fetch(:hostname) == "missing-runtime.example.com" && route.fetch(:upstream) == missing_release.refresh.route_target }
  end

  private

  def orchestrator(docker:, caddy: ValpoTestSupport::FakeCaddy.new, health_checker: ValpoTestSupport::FakeHealthChecker.new)
    Valpo::Deployments::Orchestrator.new(
      config: VALPO_TEST_CONFIG,
      docker: docker,
      caddy: caddy,
      health_checker: health_checker
    )
  end
end
