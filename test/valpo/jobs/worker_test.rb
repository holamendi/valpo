# frozen_string_literal: true

require "test_helper"

Valpo::Jobs::Worker.name

class ValpoJobsWorkerTest < Minitest::Test
  include ValpoTestDatabase

  def test_system_check_succeeds_and_unknown_job_fails
    queue = Valpo::Jobs::Queue.new
    success = queue.enqueue("system_check")
    Valpo::Jobs::Worker.new(queue:, worker_id: "worker-1").run(once: true)
    assert_equal "succeeded", queue.find(success.id).status

    failure = queue.enqueue("missing_handler")
    Valpo::Jobs::Worker.new(queue:, worker_id: "worker-1").run(once: true)
    assert_equal "failed", queue.find(failure.id).status
    assert_equal "Unknown job type: missing_handler", queue.find(failure.id).error
  end

  def test_deploy_handler_dispatches_service_id
    service = create_app_service
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_service_operation(
      "deploy_registry_image", service_id: service.id,
      payload: {project_id: service.project_id, image: "example/app:v1", internal_port: 3000}
    )
    fake = FakeDeployment.new
    worker = Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"deploy_registry_image" => Valpo::Jobs::Handlers::DeployRegistryImage.new(orchestrator: fake)},
      worker_id: "worker-1"
    )
    worker.run(once: true)

    assert_equal service.id, fake.service_id
    assert_equal "succeeded", queue.find(job.id).status
  end

  def test_bind_handler_dispatches_both_service_ids
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:)
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_service_operation(
      "bind_service", service_id: app.id,
      payload: {project_id: project.id, dependency_service_id: database.id}
    )
    fake = FakeManaged.new
    Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"bind_service" => Valpo::Jobs::Handlers::BindDependency.new(orchestrator: fake, method: :bind_service)},
      worker_id: "worker-1"
    ).run(once: true)

    assert_equal [app.id, database.id], fake.ids
    assert_equal "succeeded", queue.find(job.id).status
  end

  def test_source_deploy_handler_dispatches_ref
    service = create_app_service
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_service_operation(
      "deploy_source", service_id: service.id,
      payload: {project_id: service.project_id, ref: "release"}
    )
    fake = FakeBuild.new
    Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"deploy_source" => Valpo::Jobs::Handlers::DeploySource.new(orchestrator: fake)},
      worker_id: "worker-1"
    ).run(once: true)

    assert_equal [service.id, "release"], fake.source
    assert_equal "succeeded", queue.find(job.id).status
  end

  def test_manifest_handler_passes_normalized_manifest
    queue = Valpo::Jobs::Queue.new
    manifest = {"project" => {"name" => "hello"}}
    job = queue.enqueue("apply_project_manifest", manifest:)
    fake = FakeReconciler.new
    Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"apply_project_manifest" => Valpo::Jobs::Handlers::ApplyProjectManifest.new(reconciler: fake)},
      worker_id: "worker-1"
    ).run(once: true)
    assert_equal manifest, fake.manifest
    assert_equal "succeeded", queue.find(job.id).status
  end

  def test_source_service_handler_validates_then_creates_owned_configuration
    project = create_project
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_project_operation(
      "create_source_service",
      project_id: project.id,
      payload: source_service_payload
    )
    handler = Valpo::Jobs::Handlers::CreateSource.new(
      preflight: FakePreflight.new,
      configurator: Valpo::Sources::ServiceConfigurator.new,
      builds: FakeBuild.new
    )
    Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"create_source_service" => handler},
      worker_id: "worker-1"
    ).run(once: true)

    service = Valpo::Service.where(project_id: project.id, name: "web").first
    assert_equal "succeeded", queue.find(job.id).status
    assert service
    assert_equal service.id, Valpo::Source.first.owner_service_id
    assert_equal service.id, Valpo::BuildTarget.first.owner_service_id
    assert_equal "connected", Valpo::Source.first.status
  end

  def test_source_service_validation_failure_creates_no_records
    project = create_project
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue_project_operation(
      "create_source_service",
      project_id: project.id,
      payload: source_service_payload
    )
    handler = Valpo::Jobs::Handlers::CreateSource.new(
      preflight: FakePreflight.new(error: Valpo::ValidationError.new("GitHub fetch failed")),
      configurator: Valpo::Sources::ServiceConfigurator.new,
      builds: FakeBuild.new
    )
    Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"create_source_service" => handler},
      worker_id: "worker-1"
    ).run(once: true)

    assert_equal "failed", queue.find(job.id).status
    assert_equal 0, Valpo::Service.where(project_id: project.id).count
    assert_equal 0, Valpo::Source.where(project_id: project.id).count
    assert_equal 0, Valpo::BuildTarget.where(project_id: project.id).count
  end

  def test_source_service_build_failure_keeps_validated_configuration
    project = create_project
    queue = Valpo::Jobs::Queue.new
    payload = source_service_payload.merge(deploy: true)
    preflight = FakePreflight.new
    builds = FakeBuild.new(error: Valpo::ValidationError.new("Docker build failed"))
    job = queue.enqueue_project_operation(
      "create_source_service",
      project_id: project.id,
      payload:
    )
    handler = Valpo::Jobs::Handlers::CreateSource.new(
      preflight:,
      configurator: Valpo::Sources::ServiceConfigurator.new,
      builds:
    )

    Valpo::Jobs::Worker.new(
      queue:,
      handlers: {"create_source_service" => handler},
      worker_id: "worker-1"
    ).run(once: true)

    service = Valpo::Service.where(project_id: project.id, name: "web").first
    assert_equal "failed", queue.find(job.id).status
    assert service
    assert_equal service.id, Valpo::Source.first.owner_service_id
    assert_equal service.id, Valpo::BuildTarget.first.owner_service_id
    assert_equal 1, preflight.calls
    assert_equal "a" * 40, builds.checkout.commit
  end

  def source_service_payload
    {
      service: {name: "web", type: "web", command: [], internal_port: nil, healthcheck_path: nil},
      source: {provider: "github", repository: "acme/backend", ref: "HEAD"},
      build: {strategy: "dockerfile", dockerfile: "Dockerfile", context: "."},
      deploy: false
    }
  end

  class FakeDeployment
    attr_reader :service_id

    def deploy_registry_image(service_id:, **)
      @service_id = service_id
    end
  end

  class FakeManaged
    attr_reader :ids

    def bind_service(service_id:, dependency_service_id:, **)
      @ids = [service_id, dependency_service_id]
    end
  end

  class FakeBuild
    attr_reader :checkout, :source

    def initialize(error: nil)
      @error = error
    end

    def deploy_source(service_id:, ref:, **)
      @source = [service_id, ref]
    end

    def deploy_checkout(checkout:, **)
      @checkout = checkout
      raise @error if @error

      true
    end
  end

  class FakePreflight
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = 0
    end

    def with_checkout(**)
      @calls += 1
      raise @error if @error

      yield Valpo::Sources::Preflight::Result.new(
        checkout: "/tmp/checkout",
        strategy: "dockerfile",
        dockerfile: "/tmp/checkout/Dockerfile",
        context: "/tmp/checkout",
        commit: "a" * 40,
        ref: "HEAD"
      )
    end
  end

  class FakeReconciler
    attr_reader :manifest

    def apply(manifest, **)
      @manifest = manifest
    end
  end
end
