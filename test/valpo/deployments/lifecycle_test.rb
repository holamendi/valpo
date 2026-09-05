# frozen_string_literal: true

require "test_helper"

class ValpoDeploymentsLifecycleTest < Minitest::Test
  include ValpoTestDatabase

  def test_deploy_activates_release_routes_domain_and_injects_dependencies
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active"
    )
    domain = create_domain(service: app)
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new

    release = run_job do |queue, job|
      lifecycle(docker:, caddy:).deploy_registry_image(
        service_id: app.id,
        image: "ghcr.io/example/hello:latest",
        internal_port: nil,
        healthcheck_path: "/health",
        queue:,
        job_id: job.id
      )
    end

    assert_equal "active", release.status
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20000", domain.refresh.route_target
    expected_url = Valpo::Services::Registry.binding_environment(database).fetch("DATABASE_URL")
    assert_equal expected_url, docker.run_requests.first.fetch(:env).fetch("DATABASE_URL")
    assert_equal "3000", docker.run_requests.first.fetch(:env).fetch("PORT")
    assert_equal app.id, docker.run_requests.first.fetch(:labels).fetch("valpo.service_id")
    assert_equal "local", docker.run_requests.first.fetch(:log_driver)
    assert_equal({"max-file" => 3, "max-size" => "10m"}, docker.run_requests.first.fetch(:log_options))
  end

  def test_deploy_refuses_an_existing_network_without_the_ownership_label
    app = create_app_service
    docker = ValpoTestSupport::FakeDocker.new(network_exists: true, network_owned: false)

    error = assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:).deploy_registry_image(
          service_id: app.id,
          image: "ghcr.io/example/hello:latest",
          internal_port: 3000,
          healthcheck_path: nil,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_match "exists without valpo.owned=true", error.message
    assert_empty docker.run_requests
  end

  def test_registry_deploy_infers_one_exposed_port
    app = create_app_service(port: nil)
    docker = ValpoTestSupport::FakeDocker.new(exposed_ports: [8080])
    release = run_job do |queue, job|
      lifecycle(docker:).deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: nil,
        healthcheck_path: nil,
        queue:,
        job_id: job.id
      )
    end

    assert_equal 8080, release.internal_port
    assert_equal "8080", docker.run_requests.first.fetch(:env).fetch("PORT")
  end

  def test_built_image_without_exposed_port_uses_3000
    app = create_app_service(port: nil)
    release = run_job do |queue, job|
      lifecycle(docker: ValpoTestSupport::FakeDocker.new).deploy_built_image(
        service_id: app.id,
        image: "valpo/hello/web:abc",
        source_ref: "a" * 40,
        build_target_id: nil,
        build_strategy: "buildpack",
        build_metadata: {"builder" => "example/builder@sha256:abc"},
        internal_port: nil,
        healthcheck_path: nil,
        queue:,
        job_id: job.id
      )
    end

    assert_equal 3000, release.internal_port
  end

  def test_worker_deploy_has_no_public_port_or_route
    worker = create_app_service(name: "worker", kind: "worker", command: %w[bundle exec sidekiq])
    docker = ValpoTestSupport::FakeDocker.new
    release = run_job do |queue, job|
      lifecycle(docker:).deploy_registry_image(
        service_id: worker.id, image: "example/worker:v1", internal_port: nil,
        healthcheck_path: nil, queue:, job_id: job.id
      )
    end

    assert_nil release.route_target
    assert_equal({}, docker.run_requests.first.fetch(:ports))
    assert_equal %w[bundle exec sidekiq], docker.run_requests.first.fetch(:command_args)
  end

  def test_buildpack_command_runs_through_the_cnb_launcher
    worker = create_app_service(name: "worker", kind: "worker", command: %w[bundle exec sidekiq])
    docker = ValpoTestSupport::FakeDocker.new

    run_job do |queue, job|
      lifecycle(docker:).deploy_built_image(
        service_id: worker.id,
        image: "valpo/hello/worker:abc",
        source_ref: "a" * 40,
        build_target_id: nil,
        build_strategy: "buildpack",
        build_metadata: {"builder" => "example/builder@sha256:abc"},
        internal_port: nil,
        healthcheck_path: nil,
        queue:,
        job_id: job.id
      )
    end

    assert_equal "/cnb/lifecycle/launcher", docker.run_requests.first.fetch(:entrypoint)
    assert_equal %w[bundle exec sidekiq], docker.run_requests.first.fetch(:command_args)
  end

  def test_web_deploy_without_a_domain_stays_ready_and_private
    app = create_app_service
    caddy = ValpoTestSupport::FakeCaddy.new

    release = run_job do |queue, job|
      lifecycle(docker: ValpoTestSupport::FakeDocker.new, caddy:).deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue:,
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
    service, domains = deployment_components(docker:, caddy:)
    release = run_job do |queue, job|
      service.deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue:,
        job_id: job.id
      )
    end
    domain = Valpo::Domain.create(service_id: app.id, hostname: "hello.example.com")

    run_job { |queue, job| domains.verify_domain(domain_id: domain.id, queue:, job_id: job.id) }

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
      lifecycle(docker: ValpoTestSupport::FakeDocker.new, domain_verifier: verifier).deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue:,
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
    service, domains = deployment_components(
      docker: ValpoTestSupport::FakeDocker.new,
      domain_verifier: verifier
    )
    release = run_job do |queue, job|
      service.deploy_registry_image(
        service_id: app.id,
        image: "example/app:v1",
        internal_port: 3000,
        healthcheck_path: nil,
        queue:,
        job_id: job.id
      )
    end
    platform_domain, = Valpo::Domains::Configuration.stage("apps.example.com")

    run_job do |queue, job|
      domains.configure_platform_domain(platform_domain_id: platform_domain.id, queue:, job_id: job.id)
    end

    domain = Valpo::Domain.where(service_id: app.id, kind: "generated").first
    assert_equal "verified", platform_domain.refresh.status
    assert platform_domain.active
    assert_equal "hello-web.apps.example.com", domain.hostname
    assert_equal "verified", domain.status
    assert_equal "active", release.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal 2, verifier.requests.length
  end

  def test_platform_verification_allows_other_connections_to_write_during_network_checks
    app = create_app_service
    platform, = Valpo::Domains::Configuration.stage("example.com")
    other = Sequel.sqlite(VALPO_TEST_CONFIG.database_path)
    verifier = Object.new
    verifier.define_singleton_method(:verify!) do |hostname:, token:|
      other[:services].where(id: app.id).update(updated_at: Time.now.utc)
      true
    end
    _, domains = deployment_components(docker: ValpoTestSupport::FakeDocker.new, domain_verifier: verifier)

    run_job do |queue, job|
      domains.configure_platform_domain(platform_domain_id: platform.id, queue:, job_id: job.id)
    end

    assert platform.refresh.verified?
    assert app.domains.first.verified?
  ensure
    other&.disconnect
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
      fail_for: -> { it == "hello-web.new.example.com" }
    )
    _, domains = deployment_components(
      docker: ValpoTestSupport::FakeDocker.new,
      domain_verifier: verifier
    )

    error = assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        domains.configure_platform_domain(platform_domain_id: replacement.id, queue:, job_id: job.id)
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
      lifecycle(docker:).deploy_built_image(
        service_id: app.id,
        image: "valpo/hello/backend:abc123",
        source_ref: "a" * 40,
        build_target_id: nil,
        build_strategy: "dockerfile",
        build_metadata: {"dockerfile" => "Dockerfile"},
        internal_port: nil,
        healthcheck_path: nil,
        queue:,
        job_id: job.id
      )
    end

    assert_equal "git", release.source_type
    assert_equal "a" * 40, release.source_ref
    assert_equal "dockerfile", release.build_strategy
    assert_equal({"dockerfile" => "Dockerfile"}, release.build_metadata)
    refute docker.executed?(:pull, "valpo/hello/backend:abc123")
  end

  def test_failed_deploy_keeps_active_release
    app = create_app_service(status: "running")
    active = create_release(service: app, status: "active", container_name: "old", route_target: "127.0.0.1:20000")
    error = assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker: ValpoTestSupport::FakeDocker.new(fail_on: :run)).deploy_registry_image(
          service_id: app.id, image: "example/app:v2", internal_port: 3000,
          healthcheck_path: nil, queue:, job_id: job.id
        )
      end
    end

    assert_match "Docker run failed", error.message
    assert_equal "active", active.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal "failed", Valpo::Release.where(service_id: app.id, version: 2).first.status
  end

  def test_caddy_failure_during_deploy_restores_the_active_route_and_removes_the_candidate
    app = create_app_service(status: "running")
    create_domain(service: app)
    active = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new(fail_reloads: 1)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, caddy:).deploy_registry_image(
          service_id: app.id,
          image: "example/app:v2",
          internal_port: 3000,
          healthcheck_path: nil,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "active", active.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20000", caddy.routes.first.fetch(:upstream)
    candidate = Valpo::Release.where(service_id: app.id, version: 2).first
    assert_equal "failed", candidate.status
    assert_nil candidate.container_name
  end

  def test_database_failure_during_deploy_restores_the_active_release_and_route
    app = create_app_service(status: "running")
    create_domain(service: app)
    active = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    connection = inject_one_shot_running_failure(app, trigger_name: "fail_deploy_activation")
    caddy = ValpoTestSupport::FakeCaddy.new

    assert_raises Sequel::DatabaseError do
      run_job do |queue, job|
        lifecycle(docker: ValpoTestSupport::FakeDocker.new, caddy:).deploy_registry_image(
          service_id: app.id,
          image: "example/app:v2",
          internal_port: 3000,
          healthcheck_path: nil,
          queue:,
          job_id: job.id
        )
      end
    end

    candidate = Valpo::Release.where(service_id: app.id, version: 2).first
    assert_equal "active", active.refresh.status
    assert_equal "failed", candidate.status
    assert_nil candidate.container_name
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20000", caddy.routes.first.fetch(:upstream)
  ensure
    connection&.run("DROP TRIGGER IF EXISTS fail_deploy_activation")
  end

  def test_deploy_succeeds_when_retiring_the_previous_release_fails
    %i[stop rm].each_with_index do |failure, index|
      app = create_app_service(
        project: create_project(name: "deploy-retirement-#{index}"),
        status: "running"
      )
      create_domain(service: app, hostname: "deploy-retirement-#{index}.example.com")
      previous = create_release(
        service: app,
        status: "active",
        container_name: "old-#{index}",
        route_target: "127.0.0.1:#{20_000 + index}"
      )
      docker = ValpoTestSupport::FakeDocker.new(fail_on: failure)

      release = run_job do |queue, job|
        result = lifecycle(docker:).deploy_registry_image(
          service_id: app.id,
          image: "example/app:v2",
          internal_port: 3000,
          healthcheck_path: nil,
          queue:,
          job_id: job.id
        )
        assert queue.events(job.id).any? {
          it.stream == "stderr" && it.message.include?("Could not retire release 1")
        }
        result
      end

      assert_equal "active", release.status
      assert_equal "inactive", previous.refresh.status
      assert_equal "old-#{index}", previous.container_name
      assert_equal "running", app.refresh.status
    end
  end

  def test_rollback_reactivates_previous_release
    app = create_app_service(status: "running")
    create_domain(service: app)
    previous = create_release(service: app, image: "example/app:v1", status: "inactive", container_name: "previous", route_target: "127.0.0.1:20000")
    current = create_release(service: app, image: "example/app:v2", status: "active", container_name: "current", route_target: "127.0.0.1:20001")
    rolled_back = run_job { |queue, job| lifecycle(docker: ValpoTestSupport::FakeDocker.new).rollback_service(service_id: app.id, queue:, job_id: job.id) }

    assert_equal previous.id, rolled_back.id
    assert_equal "active", previous.refresh.status
    assert_equal "inactive", current.refresh.status
  end

  def test_caddy_failure_during_rollback_restores_the_current_release
    app = create_app_service(status: "running")
    create_domain(service: app)
    previous = create_release(
      service: app,
      image: "example/app:v1",
      status: "inactive",
      container_name: "previous",
      route_target: "127.0.0.1:20000"
    )
    current = create_release(
      service: app,
      image: "example/app:v2",
      status: "active",
      container_name: "current",
      route_target: "127.0.0.1:20001"
    )
    caddy = ValpoTestSupport::FakeCaddy.new(fail_reloads: 1)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker: ValpoTestSupport::FakeDocker.new, caddy:).rollback_service(
          service_id: app.id,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "inactive", previous.refresh.status
    assert_equal "previous", previous.container_name
    assert_equal "active", current.refresh.status
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20001", caddy.routes.first.fetch(:upstream)
  end

  def test_database_failure_during_rollback_restores_release_metadata_and_routes
    app = create_app_service(status: "running")
    create_domain(service: app)
    previous = create_release(
      service: app,
      image: "example/app:v1",
      status: "inactive",
      container_name: "previous",
      route_target: "127.0.0.1:20000"
    )
    current = create_release(
      service: app,
      image: "example/app:v2",
      status: "active",
      container_name: "current",
      route_target: "127.0.0.1:20001"
    )
    connection = inject_one_shot_running_failure(app, trigger_name: "fail_rollback_activation")
    caddy = ValpoTestSupport::FakeCaddy.new

    assert_raises Sequel::DatabaseError do
      run_job do |queue, job|
        lifecycle(docker: ValpoTestSupport::FakeDocker.new, caddy:).rollback_service(
          service_id: app.id,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "inactive", previous.refresh.status
    assert_equal "previous", previous.container_name
    assert_equal "127.0.0.1:20000", previous.route_target
    assert_equal "active", current.refresh.status
    assert_equal "current", current.container_name
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20001", caddy.routes.first.fetch(:upstream)
  ensure
    connection&.run("DROP TRIGGER IF EXISTS fail_rollback_activation")
  end

  def test_rollback_succeeds_when_retiring_the_current_release_fails
    %i[stop rm].each_with_index do |failure, index|
      app = create_app_service(
        project: create_project(name: "rollback-retirement-#{index}"),
        status: "running"
      )
      create_domain(service: app, hostname: "rollback-retirement-#{index}.example.com")
      previous = create_release(
        service: app,
        image: "example/app:v1",
        status: "inactive",
        container_name: "previous-#{index}",
        route_target: "127.0.0.1:#{20_000 + index}"
      )
      current = create_release(
        service: app,
        image: "example/app:v2",
        status: "active",
        container_name: "current-#{index}",
        route_target: "127.0.0.1:#{21_000 + index}"
      )

      rolled_back = run_job do |queue, job|
        result = lifecycle(docker: ValpoTestSupport::FakeDocker.new(fail_on: failure)).rollback_service(
          service_id: app.id,
          queue:,
          job_id: job.id
        )
        assert queue.events(job.id).any? {
          it.stream == "stderr" && it.message.include?("Could not retire release 2")
        }
        result
      end

      assert_equal previous.id, rolled_back.id
      assert_equal "active", previous.refresh.status
      assert_equal "inactive", current.refresh.status
      assert_equal "current-#{index}", current.container_name
      assert_equal "running", app.refresh.status
    end
  end

  def test_restart_succeeds_when_removing_the_previous_container_fails
    %i[stop rm].each_with_index do |failure, index|
      app = create_app_service(
        project: create_project(name: "restart-retirement-#{index}"),
        status: "running"
      )
      create_domain(service: app, hostname: "restart-retirement-#{index}.example.com")
      old_container = "old-#{index}"
      release = create_release(
        service: app,
        status: "active",
        container_name: old_container,
        route_target: "127.0.0.1:#{20_000 + index}"
      )
      docker = ValpoTestSupport::FakeDocker.new(fail_on: failure)

      restarted = run_job do |queue, job|
        result = lifecycle(docker:).restart_service(service_id: app.id, queue:, job_id: job.id)
        assert queue.events(job.id).any? {
          it.stream == "stderr" && it.message.include?("Could not retire container #{old_container}")
        }
        result
      end

      assert_equal release.id, restarted.id
      refute_equal old_container, release.refresh.container_name
      assert_equal "active", release.status
      assert_equal "running", app.refresh.status
    end
  end

  def test_caddy_failure_during_restart_restores_release_metadata_before_routes
    app = create_app_service(status: "running")
    create_domain(service: app)
    release = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new(fail_reloads: 1)

    assert_raises Valpo::ValidationError do
      run_job do |queue, job|
        lifecycle(docker:, caddy:).restart_service(service_id: app.id, queue:, job_id: job.id)
      end
    end

    assert_equal "old", release.refresh.container_name
    assert_equal "127.0.0.1:20000", release.route_target
    assert_equal "active", release.status
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20000", caddy.routes.first.fetch(:upstream)
    candidate_name = docker.run_requests.first.fetch(:name)
    assert docker.executed?(:stop, candidate_name)
    assert docker.executed?(:rm, candidate_name, true)
  end

  def test_database_failure_during_restart_restores_release_metadata_and_routes
    app = create_app_service(status: "running")
    create_domain(service: app)
    release = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    connection = inject_one_shot_running_failure(app, trigger_name: "fail_restart_activation")
    caddy = ValpoTestSupport::FakeCaddy.new

    assert_raises Sequel::DatabaseError do
      run_job do |queue, job|
        lifecycle(docker: ValpoTestSupport::FakeDocker.new, caddy:).restart_service(
          service_id: app.id,
          queue:,
          job_id: job.id
        )
      end
    end

    assert_equal "old", release.refresh.container_name
    assert_equal "127.0.0.1:20000", release.route_target
    assert_equal "active", release.status
    assert_equal "running", app.refresh.status
    assert_equal "127.0.0.1:20000", caddy.routes.first.fetch(:upstream)
  ensure
    connection&.run("DROP TRIGGER IF EXISTS fail_restart_activation")
  end

  def test_stop_restart_and_logs_are_service_scoped
    app = create_app_service(status: "running")
    release = create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    domain = create_domain(service: app, route_target: release.route_target)
    docker = ValpoTestSupport::FakeDocker.new
    service = lifecycle(docker:)

    run_job { |queue, job| service.stop_service(service_id: app.id, queue:, job_id: job.id) }
    assert_equal "stopped", app.refresh.status
    assert_nil domain.refresh.route_target

    run_job { |queue, job| service.restart_service(service_id: app.id, queue:, job_id: job.id) }
    assert_equal "running", app.refresh.status
    assert_equal "app log\n", service.app_logs(service_id: app.id, tail: 10).fetch(:stdout)
  end

  def test_delete_app_requires_force_and_removes_runtime
    app = create_app_service(status: "running")
    create_release(service: app, status: "active", container_name: "active", route_target: "127.0.0.1:20000")
    docker = ValpoTestSupport::FakeDocker.new
    assert_raises(Valpo::ValidationError) do
      run_job { |queue, job| lifecycle(docker:).delete_app_service(service_id: app.id, force: false, queue:, job_id: job.id) }
    end
    run_job { |queue, job| lifecycle(docker:).delete_app_service(service_id: app.id, force: true, queue:, job_id: job.id) }
    assert_nil Valpo::Service[app.id]
    assert docker.executed?(:stop, "active")
  end

  def test_delete_owned_source_service_removes_its_buildpack_caches
    project = create_project
    configuration = Valpo::Sources::ServiceConfigurator.new.normalize_create(
      source: {provider: "github", repository: "acme/backend"},
      build: {strategy: "buildpack"}
    )
    app = Valpo::Sources::ServiceConfigurator.new.create_service!(
      project:,
      service_attributes: {"name" => "web", "type" => "web"},
      source: configuration.fetch(:source),
      build: configuration.fetch(:build)
    )
    target_id = Valpo::AppServiceConfig[app.id].build_target_id
    docker = ValpoTestSupport::FakeDocker.new
    cache_manager = Valpo::Builds::CacheManager.new(docker:)

    run_job do |queue, job|
      lifecycle(docker:, build_cache_manager: cache_manager).delete_app_service(
        service_id: app.id,
        force: true,
        queue:,
        job_id: job.id
      )
    end

    assert docker.executed?(:volume_rm, "valpo-cnb-build-#{target_id}", true)
    assert docker.executed?(:volume_rm, "valpo-cnb-launch-#{target_id}", true)
  end

  def test_project_delete_refuses_until_services_are_removed
    project = create_project
    create_app_service(project:)
    assert_raises(Valpo::ConflictError) do
      run_job { |queue, job| lifecycle(docker: ValpoTestSupport::FakeDocker.new).delete_project(project_id: project.id, queue:, job_id: job.id) }
    end
  end

  def test_project_delete_removes_manifest_buildpack_caches
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend"
    )
    target = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "backend",
      strategy: "buildpack"
    )
    docker = ValpoTestSupport::FakeDocker.new
    cache_manager = Valpo::Builds::CacheManager.new(docker:)

    run_job do |queue, job|
      lifecycle(docker:, build_cache_manager: cache_manager).delete_project(
        project_id: project.id,
        queue:,
        job_id: job.id
      )
    end

    assert_nil Valpo::Project[project.id]
    assert docker.executed?(:volume_rm, "valpo-cnb-build-#{target.id}", true)
    assert docker.executed?(:volume_rm, "valpo-cnb-launch-#{target.id}", true)
  end

  def test_repair_restarts_stopped_and_recreates_missing_app_containers
    stopped = create_app_service(name: "stopped", status: "failed")
    stopped_release = create_release(service: stopped, status: "active", container_name: "stopped-container", route_target: "127.0.0.1:20000")
    missing = create_app_service(project: stopped.project, name: "missing", status: "running")
    missing_release = create_release(service: missing, image: "example/missing:v1", status: "active", container_name: "missing-container", route_target: "127.0.0.1:20001")
    docker = ValpoTestSupport::FakeDocker.new(container_states: {"stopped-container" => false, "missing-container" => :missing})

    run_job { |queue, job| system_repairer(docker:).repair(queue:, job_id: job.id) }

    assert docker.executed?(:start, stopped_release.container_name)
    assert_equal "running", stopped.refresh.status
    refute_equal "missing-container", missing_release.refresh.container_name
    assert_equal "running", missing.refresh.status
  end

  private

  def inject_one_shot_running_failure(service, trigger_name:)
    connection = Valpo::Database.connection
    function_name = "#{trigger_name}_once"
    attempts = 0
    connection.synchronize do |raw_connection|
      raw_connection.create_function(function_name, 0) do
        attempts += 1
        it.result = (attempts == 1) ? 1 : 0
      end
    end
    connection.run(<<~SQL)
      CREATE TRIGGER #{trigger_name}
      BEFORE UPDATE OF status ON services
      WHEN OLD.id = #{connection.literal(service.id)}
        AND NEW.status = 'running'
        AND #{function_name}() = 1
      BEGIN
        SELECT RAISE(FAIL, 'injected activation failure');
      END
    SQL
    connection
  end

  def run_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    yield queue, job
  end

  def lifecycle(
    docker:,
    caddy: ValpoTestSupport::FakeCaddy.new,
    domain_verifier: ValpoTestSupport::FakeDomainVerifier.new,
    build_cache_manager: nil
  )
    deployment_components(docker:, caddy:, domain_verifier:, build_cache_manager:).first
  end

  def deployment_components(
    docker:,
    caddy: ValpoTestSupport::FakeCaddy.new,
    domain_verifier: ValpoTestSupport::FakeDomainVerifier.new,
    build_cache_manager: nil
  )
    caddy_reconciler = Valpo::Caddy::Reconciler.new(caddy:)
    activator = Valpo::Deployments::Activator.new(caddy_reconciler:)
    domains = Valpo::Domains::Orchestrator.new(
      caddy_reconciler:,
      activator:,
      config: VALPO_TEST_CONFIG,
      docker:,
      verifier: domain_verifier
    )
    lifecycle = Valpo::Deployments::Lifecycle.new(
      config: VALPO_TEST_CONFIG,
      docker:,
      caddy:,
      health_checker: ValpoTestSupport::FakeHealthChecker.new,
      caddy_reconciler:,
      activator:,
      domain_orchestrator: domains,
      build_cache_manager:
    )
    [lifecycle, domains]
  end

  def system_repairer(docker:)
    caddy_reconciler = Valpo::Caddy::Reconciler.new(caddy: ValpoTestSupport::FakeCaddy.new)
    Valpo::System::Repairer.new(
      managed_lifecycle: FakeServiceRepair.new,
      deployment_repairer: Valpo::Deployments::Repairer.new(
        config: VALPO_TEST_CONFIG,
        docker:,
        health_checker: ValpoTestSupport::FakeHealthChecker.new
      ),
      caddy_reconciler:
    )
  end

  class FakeServiceRepair
    def repair_services(queue:, job_id:)
      queue.event(job_id, "system", "managed services repaired")
    end
  end
end
