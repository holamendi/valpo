# frozen_string_literal: true

require "test_helper"

class ValpoServicesAppUpdaterTest < Minitest::Test
  include ValpoTestDatabase

  def test_source_update_detaches_from_manifest_configuration
    service, manifest_source, = configured_service
    configuration = {
      "source" => {"provider" => "github", "repository" => "acme/new-backend", "ref" => "release"},
      "build" => {"dockerfile" => "ops/Dockerfile", "context" => "."}
    }

    updater.update(
      service_id: service.id,
      configuration:,
      runtime_changes: {},
      deploy: false,
      queue: FakeQueue.new,
      job_id: "job_test"
    )

    owned_source = Valpo::Source.where(owner_service_id: service.id).first
    owned_build = Valpo::BuildTarget.where(owner_service_id: service.id).first
    assert_equal "acme/backend", manifest_source.refresh.repository
    assert_equal "acme/new-backend", owned_source.repository
    assert_equal owned_build.id, Valpo::AppServiceConfig[service.id].build_target_id
  end

  def test_failed_preflight_does_not_change_configuration
    service, source, build = configured_service
    failing = updater(preflight: FakePreflight.new(error: Valpo::ValidationError.new("missing ref")))

    assert_raises Valpo::ValidationError do
      failing.update(
        service_id: service.id,
        configuration: {
          "source" => {"provider" => "github", "repository" => "acme/backend", "ref" => "missing"},
          "build" => {"dockerfile" => "Dockerfile", "context" => "."}
        },
        runtime_changes: {},
        deploy: false,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    assert_equal build.id, Valpo::AppServiceConfig[service.id].build_target_id
    assert_equal "main", source.refresh.ref
    assert_nil Valpo::Source.where(owner_service_id: service.id).first
  end

  def test_runtime_update_reconfigures_running_release
    service = create_app_service(status: "running", port: 3000)
    create_release(service:, status: "active", container_name: "active")
    deployment = FakeDeployment.new

    updater(deployment:).update(
      service_id: service.id,
      configuration: nil,
      runtime_changes: {"internal_port" => 9292, "healthcheck_path" => "/health"},
      deploy: false,
      queue: FakeQueue.new,
      job_id: "job_test"
    )

    assert_equal service.id, deployment.service_id
    assert_equal 9292, Valpo::AppServiceConfig[service.id].internal_port
    assert_equal "/health", Valpo::AppServiceConfig[service.id].healthcheck_path
  end

  def test_failed_runtime_update_restores_previous_configuration
    service = create_app_service(status: "running", port: 3000)
    create_release(service:, status: "active", container_name: "active")
    failing = updater(deployment: FakeDeployment.new(error: Valpo::ValidationError.new("restart failed")))

    assert_raises Valpo::ValidationError do
      failing.update(
        service_id: service.id,
        configuration: nil,
        runtime_changes: {"internal_port" => 9292},
        deploy: false,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    assert_equal 3000, Valpo::AppServiceConfig[service.id].internal_port
    assert_equal "running", service.refresh.status
  end

  def test_failed_redeploy_restores_source_build_runtime_and_active_release
    project = create_project
    service = Valpo::Sources::ServiceConfigurator.new.create_service!(
      project:,
      service_attributes: {"name" => "web", "type" => "web", "internal_port" => 3000},
      source: {"provider" => "github", "repository" => "acme/backend", "ref" => "main"},
      build: {"dockerfile" => "Dockerfile", "context" => "."}
    )
    service.update(status: "running")
    active = create_release(service:, status: "active", container_name: "active", internal_port: 3000)
    failing_builds = FakeBuilds.new(error: Valpo::ValidationError.new("Docker build failed"))

    assert_raises Valpo::ValidationError do
      updater(builds: failing_builds).update(
        service_id: service.id,
        configuration: {
          "source" => {"provider" => "github", "repository" => "acme/new-backend", "ref" => "release"},
          "build" => {"dockerfile" => "ops/Dockerfile", "context" => "app"}
        },
        runtime_changes: {"internal_port" => 9292},
        deploy: true,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    source = Valpo::Source.where(owner_service_id: service.id).first
    build = Valpo::BuildTarget.where(owner_service_id: service.id).first
    app = Valpo::AppServiceConfig[service.id]
    assert_equal ["acme/backend", "main"], [source.repository, source.ref]
    assert_equal ["Dockerfile", "."], [build.dockerfile, build.context]
    assert_equal 3000, app.internal_port
    assert_equal "running", service.refresh.status
    assert_equal "active", active.refresh.status
  end

  def test_service_owned_configuration_is_deleted_with_the_service
    project = create_project
    service = Valpo::Sources::ServiceConfigurator.new.create_service!(
      project:,
      service_attributes: {"name" => "web", "type" => "web"},
      source: {"provider" => "github", "repository" => "acme/backend", "ref" => "HEAD"},
      build: {"dockerfile" => "Dockerfile", "context" => "."}
    )

    service.destroy

    assert_equal 0, Valpo::Source.where(project_id: project.id).count
    assert_equal 0, Valpo::BuildTarget.where(project_id: project.id).count
  end

  def test_service_deletion_does_not_remove_manifest_owned_configuration
    service, source, build = configured_service

    service.destroy

    assert Valpo::Source[source.id]
    assert Valpo::BuildTarget[build.id]
  end

  private

  def configured_service
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend",
      ref: "main"
    )
    build = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "backend",
      dockerfile: "Dockerfile",
      context: "."
    )
    service = create_app_service(project:)
    Valpo::AppServiceConfig[service.id].update(build_target_id: build.id)
    [service, source, build]
  end

  def updater(preflight: FakePreflight.new, builds: FakeBuilds.new, deployment: FakeDeployment.new)
    Valpo::Services::AppUpdater.new(
      preflight:,
      configurator: Valpo::Sources::ServiceConfigurator.new,
      builds:,
      deployment:
    )
  end

  class FakePreflight
    def initialize(error: nil)
      @error = error
    end

    def with_checkout(**)
      raise @error if @error

      yield Valpo::Sources::Preflight::Result.new(
        checkout: "/tmp/checkout",
        dockerfile: "/tmp/checkout/Dockerfile",
        context: "/tmp/checkout",
        commit: "a" * 40,
        ref: "release"
      )
    end
  end

  class FakeBuilds
    def initialize(error: nil)
      @error = error
    end

    def deploy_checkout(**)
      raise @error if @error

      true
    end

    def deploy_source(**)
      raise @error if @error

      true
    end
  end

  class FakeDeployment
    attr_reader :service_id

    def initialize(error: nil)
      @error = error
    end

    def reconfigure_service(service_id:, **)
      raise @error if @error

      @service_id = service_id
    end
  end

  class FakeQueue
    def event(*)
    end
  end
end
