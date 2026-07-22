# frozen_string_literal: true

require "test_helper"

class ValpoDeploymentsOrchestratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_deploy_activates_release_routes_domain_and_injects_dependencies
    project = create_project
    app = create_app_service(project: project)
    database = create_managed_service(project: project)
    Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active",
      env_json: JSON.generate("DATABASE_URL" => "postgres://example")
    )
    domain = create_domain(service: app)
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new

    release = run_job do |queue, job|
      orchestrator(docker: docker, caddy: caddy).deploy_registry_image(
        service_id: app.id,
        image: "ghcr.io/example/hello:latest",
        internal_port: nil,
        healthcheck_path: "/health",
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal "active", release.status
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20000", domain.refresh.route_target
    assert_equal "postgres://example", docker.run_requests.first.fetch(:env).fetch("DATABASE_URL")
    assert_equal "3000", docker.run_requests.first.fetch(:env).fetch("PORT")
    assert_equal app.id, docker.run_requests.first.fetch(:labels).fetch("valpo.service_id")
  end

  def test_registry_deploy_infers_one_exposed_port
    app = create_app_service(port: nil)
    docker = ValpoTestSupport::FakeDocker.new(exposed_ports: [8080])
    release = run_job do |queue, job|
      orchestrator(docker: docker).deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: nil,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal 8080, release.internal_port
    assert_equal "8080", docker.run_requests.first.fetch(:env).fetch("PORT")
  end

  def test_built_image_without_exposed_port_uses_3000
    app = create_app_service(port: nil)
    release = run_job do |queue, job|
      orchestrator(docker: ValpoTestSupport::FakeDocker.new).deploy_built_image(
        service_id: app.id,
        image: "valpo/hello/web:abc",
        source_ref: "a" * 40,
        build_target_id: nil,
        internal_port: nil,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal 3000, release.internal_port
  end

  def test_worker_deploy_has_no_public_port_or_route
    worker = create_app_service(name: "worker", kind: "worker", command: %w[bundle exec sidekiq])
    docker = ValpoTestSupport::FakeDocker.new
    release = run_job do |queue, job|
      orchestrator(docker: docker).deploy_registry_image(
        service_id: worker.id, image: "example/worker:v1", internal_port: nil,
        healthcheck_path: nil, queue: queue, job_id: job.id
      )
    end

    assert_nil release.route_target
    assert_equal({}, docker.run_requests.first.fetch(:ports))
    assert_equal %w[bundle exec sidekiq], docker.run_requests.first.fetch(:command_args)
  end

  def test_web_deploy_without_a_domain_stays_ready_and_private
    app = create_app_service
    caddy = ValpoTestSupport::FakeCaddy.new

    release = run_job do |queue, job|
      orchestrator(docker: ValpoTestSupport::FakeDocker.new, caddy: caddy).deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal "ready", release.status
    assert_equal "ready", app.refresh.status
    assert release.container_name
    assert_nil caddy.routes
  end

  def test_verifying_domain_activates_ready_release
    app = create_app_service
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new
    service = orchestrator(docker: docker, caddy: caddy)
    release = run_job do |queue, job|
      service.deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end
    domain = Valpo::Domain.create(service_id: app.id, hostname: "hello.example.com")

    run_job { |queue, job| service.verify_domain(domain_id: domain.id, queue: queue, job_id: job.id) }

    assert_equal "active", release.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal "verified", domain.refresh.status
    assert_equal "127.0.0.1:20000", domain.route_target
  end

  def test_failed_domain_verification_keeps_deployment_ready_and_private
    app = create_app_service
    domain = Valpo::Domain.create(service_id: app.id, hostname: "missing.example.com")
    verifier = ValpoTestSupport::FakeDomainVerifier.new(error: Valpo::ValidationError.new("challenge unavailable"))

    release = run_job do |queue, job|
      orchestrator(docker: ValpoTestSupport::FakeDocker.new, domain_verifier: verifier).deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal "ready", release.status
    assert_equal "ready", app.refresh.status
    assert_equal "failed", domain.refresh.status
    assert_match "challenge unavailable", domain.verification_error
  end

  def test_configuring_platform_domain_backfills_and_activates_ready_web_release
    app = create_app_service
    verifier = ValpoTestSupport::FakeDomainVerifier.new
    service = orchestrator(docker: ValpoTestSupport::FakeDocker.new, domain_verifier: verifier)
    release = run_job do |queue, job|
      service.deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end
    platform_domain, = Valpo::Domains::Configuration.stage("apps.example.com")

    run_job do |queue, job|
      service.configure_platform_domain(platform_domain_id: platform_domain.id, queue: queue, job_id: job.id)
    end

    domain = Valpo::Domain.where(service_id: app.id, kind: "generated").first
    assert_equal "verified", platform_domain.refresh.status
    assert platform_domain.active
    assert_equal "web.hello.apps.example.com", domain.hostname
    assert_equal "verified", domain.status
    assert_equal "active", release.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal 2, verifier.requests.length
  end

  def test_failed_generated_domain_replacement_keeps_previous_verified_hostname
    old_platform = create_platform_domain(hostname: "old.example.com")
    app = create_app_service(status: "running")
    old_domain = Valpo::Domain.where(service_id: app.id, platform_domain_id: old_platform.id).first
    old_domain.update(status: "verified", verified_at: Time.now.utc)
    create_release(service: app, status: "active", route_target: "127.0.0.1:20000")
    replacement, = Valpo::Domains::Configuration.stage("new.example.com")
    verifier = ValpoTestSupport::FakeDomainVerifier.new(
      error: Valpo::ValidationError.new("exact hostname is not reachable"),
      fail_for: ->(hostname) { hostname == "web.hello.new.example.com" }
    )
    service = orchestrator(docker: ValpoTestSupport::FakeDocker.new, domain_verifier: verifier)

    error = assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        service.configure_platform_domain(platform_domain_id: replacement.id, queue: queue, job_id: job.id)
      end
    end

    assert_match "exact hostname is not reachable", error.message
    assert_equal "verified", old_domain.refresh.status
    assert Valpo::Domain[old_domain.id]
    assert_equal "failed", Valpo::Domain.where(service_id: app.id, platform_domain_id: replacement.id).first.status
  end

  def test_built_image_deploy_skips_pull_and_records_git_metadata
    app = create_app_service
    docker = ValpoTestSupport::FakeDocker.new
    release = run_job do |queue, job|
      orchestrator(docker: docker).deploy_built_image(
        service_id: app.id,
        image: "valpo/hello/backend:abc123",
        source_ref: "a" * 40,
        build_target_id: nil,
        internal_port: nil,
        healthcheck_path: nil,
        queue: queue,
        job_id: job.id
      )
    end

    assert_equal "git", release.source_type
    assert_equal "a" * 40, release.source_ref
    refute docker.executed?(:pull, "valpo/hello/backend:abc123")
  end

  def test_failed_deploy_keeps_active_release
    app = create_app_service(status: "running")
    active = create_release(service: app, status: "active", container_name: "old", route_target: "127.0.0.1:20000")
    error = assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        orchestrator(docker: ValpoTestSupport::FakeDocker.new(fail_on: :run)).deploy_registry_image(
          service_id: app.id, image: "example/app:v2", internal_port: 3000,
          healthcheck_path: nil, queue: queue, job_id: job.id
        )
      end
    end

    assert_match "Docker run failed", error.message
    assert_equal "active", active.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal "failed", Valpo::Release.where(service_id: app.id, version: 2).first.status
  end

  def test_rollback_reactivates_previous_release
    app = create_app_service(status: "running")
    create_domain(service: app)
    previous = create_release(service: app, image: "example/app:v1", status: "inactive", container_name: "previous", route_target: "127.0.0.1:20000")
    current = create_release(service: app, image: "example/app:v2", status: "active", container_name: "current", route_target: "127.0.0.1:20001")
    rolled_back = run_job { |queue, job| orchestrator(docker: ValpoTestSupport::FakeDocker.new).rollback_service(service_id: app.id, queue: queue, job_id: job.id) }

    assert_equal previous.id, rolled_back.id
    assert_equal "active", previous.refresh.status
    assert_equal "inactive", current.refresh.status
  end

  def test_stop_restart_and_logs_are_service_scoped
    app = create_app_service(status: "running")
    release = create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    domain = create_domain(service: app, route_target: release.route_target)
    docker = ValpoTestSupport::FakeDocker.new
    service = orchestrator(docker: docker)

    run_job { |queue, job| service.stop_service(service_id: app.id, queue: queue, job_id: job.id) }
    assert_equal "stopped", app.refresh.status
    assert_nil domain.refresh.route_target

    run_job { |queue, job| service.restart_service(service_id: app.id, queue: queue, job_id: job.id) }
    assert_equal "running", app.refresh.status
    assert_equal "app log\n", service.app_logs(service_id: app.id, tail: 10).fetch(:stdout)
  end

  def test_delete_app_requires_force_and_removes_runtime
    app = create_app_service(status: "running")
    create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    docker = ValpoTestSupport::FakeDocker.new
    assert_raises(Valpo::ValidationError) do
      run_job { |queue, job| orchestrator(docker: docker).delete_app_service(service_id: app.id, force: false, queue: queue, job_id: job.id) }
    end
    run_job { |queue, job| orchestrator(docker: docker).delete_app_service(service_id: app.id, force: true, queue: queue, job_id: job.id) }
    assert_nil Valpo::Service[app.id]
    assert docker.executed?(:stop, "active")
  end

  def test_project_delete_refuses_until_services_are_removed
    project = create_project
    create_app_service(project: project)
    assert_raises(Valpo::ConflictError) do
      run_job { |queue, job| orchestrator(docker: ValpoTestSupport::FakeDocker.new).delete_project(project_id: project.id, queue: queue, job_id: job.id) }
    end
  end

  def test_repair_restarts_stopped_and_recreates_missing_app_containers
    stopped = create_app_service(name: "stopped", status: "failed")
    stopped_release = create_release(service: stopped, status: "active", container_name: "stopped-container", route_target: "127.0.0.1:20000")
    missing = create_app_service(project: stopped.project, name: "missing", status: "running")
    missing_release = create_release(service: missing, image: "example/missing:v1", status: "active", container_name: "missing-container", route_target: "127.0.0.1:20001")
    docker = ValpoTestSupport::FakeDocker.new(container_states: {"stopped-container" => false, "missing-container" => :missing})

    run_job { |queue, job| orchestrator(docker: docker).repair_system(queue: queue, job_id: job.id) }

    assert docker.executed?(:start, stopped_release.container_name)
    assert_equal "running", stopped.refresh.status
    refute_equal "missing-container", missing_release.refresh.container_name
    assert_equal "running", missing.refresh.status
  end

  private

  def run_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")
    yield queue, job
  end

  def orchestrator(docker:, caddy: ValpoTestSupport::FakeCaddy.new, domain_verifier: ValpoTestSupport::FakeDomainVerifier.new)
    Valpo::Deployments::Orchestrator.new(
      config: VALPO_TEST_CONFIG,
      docker: docker,
      caddy: caddy,
      health_checker: ValpoTestSupport::FakeHealthChecker.new,
      domain_verifier: domain_verifier,
      service_orchestrator: FakeServiceRepair.new
    )
  end

  class FakeServiceRepair
    def repair_services(queue:, job_id:)
      queue.event(job_id, "system", "managed services repaired")
    end
  end
end
