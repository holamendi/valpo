# frozen_string_literal: true

require "test_helper"

class ValpoBuildsOrchestratorTest < Minitest::Test
  include ValpoTestDatabase

  COMMIT = "b" * 40

  def test_builds_configured_source_and_deploys_the_commit
    service, source, build_target = configured_service
    fetcher = FakeFetcher.new
    dockerfile_builder = FakeBuilder.new(strategy: "dockerfile")
    deployment = FakeDeployment.new
    lock = FakeLock.new

    release = orchestrator(fetcher:, deployment:, dockerfile_builder:, lock:).deploy_source(
      service_id: service.id,
      ref: "release",
      internal_port: nil,
      healthcheck_path: nil,
      queue: FakeQueue.new,
      job_id: "job_test"
    )

    assert_equal :release, release
    assert_equal "connected", source.refresh.status
    assert_equal "release", fetcher.ref
    assert_equal build_target.id, deployment.arguments.fetch(:build_target_id)
    assert_equal COMMIT, deployment.arguments.fetch(:source_ref)
    assert_equal "valpo/hello/backend:#{COMMIT[0, 12]}", deployment.arguments.fetch(:image)
    assert_equal "dockerfile", deployment.arguments.fetch(:build_strategy)
    assert_equal({"dockerfile" => "Dockerfile"}, deployment.arguments.fetch(:build_metadata))
    assert_equal build_target.id, dockerfile_builder.arguments.fetch(:build_target).id
    assert_equal [build_target.id], lock.ids
  end

  def test_auto_uses_buildpack_builder_without_a_dockerfile
    service, _, build_target = configured_service(strategy: "auto", dockerfile: nil)
    dockerfile_builder = FakeBuilder.new(strategy: "dockerfile")
    buildpack_builder = FakeBuilder.new(strategy: "buildpack")
    deployment = FakeDeployment.new

    orchestrator(
      fetcher: FakeFetcher.new(dockerfile: false),
      deployment:,
      dockerfile_builder:,
      buildpack_builder:
    ).deploy_source(
      service_id: service.id,
      ref: nil,
      internal_port: nil,
      healthcheck_path: nil,
      queue: FakeQueue.new,
      job_id: "job_test"
    )

    assert_nil dockerfile_builder.arguments
    assert_equal build_target.id, buildpack_builder.arguments.fetch(:build_target).id
    assert_equal "buildpack", deployment.arguments.fetch(:build_strategy)
  end

  def test_failed_build_does_not_touch_the_active_release
    service, source, = configured_service
    service.update(status: "running")
    active = create_release(service:, status: "active")
    deployment = FakeDeployment.new
    buildpack_builder = FakeBuilder.new(strategy: "buildpack")

    error = assert_raises Valpo::ValidationError do
      orchestrator(
        fetcher: FakeFetcher.new,
        dockerfile_builder: FakeBuilder.new(strategy: "dockerfile", error: Valpo::ValidationError.new("Docker build failed")),
        buildpack_builder:,
        deployment:
      ).deploy_source(
        service_id: service.id,
        ref: nil,
        internal_port: nil,
        healthcheck_path: nil,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    assert_match "Docker build failed", error.message
    assert_equal "connected", source.refresh.status
    assert_equal "running", service.refresh.status
    assert_equal "active", active.refresh.status
    failed = Valpo::Release.where(service_id: service.id, status: "failed").first
    assert failed
    assert_equal COMMIT, failed.source_ref
    assert_equal "dockerfile", failed.build_strategy
    assert_equal({"dockerfile" => "Dockerfile"}, failed.build_metadata)
    assert_nil buildpack_builder.arguments
    assert_nil deployment.arguments
  end

  def test_failed_initial_build_records_a_failed_release_without_activating_it
    service, = configured_service

    assert_raises Valpo::ValidationError do
      orchestrator(
        fetcher: FakeFetcher.new,
        dockerfile_builder: FakeBuilder.new(strategy: "dockerfile", error: Valpo::ValidationError.new("Docker build failed")),
        deployment: FakeDeployment.new
      ).deploy_source(
        service_id: service.id,
        ref: nil,
        internal_port: nil,
        healthcheck_path: nil,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    assert_equal "failed", service.refresh.status
    assert_nil Valpo::Release.active_for_service(service.id)
    assert_equal 1, Valpo::Release.where(service_id: service.id).count
    failed = Valpo::Release.where(service_id: service.id).first
    assert_equal "failed", failed.status
    assert_equal COMMIT, failed.source_ref
  end

  private

  def configured_service(strategy: "dockerfile", dockerfile: "Dockerfile")
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend",
      ref: "main"
    )
    build_target = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "backend",
      strategy:,
      dockerfile:,
      context: "."
    )
    service = create_app_service(project:)
    Valpo::AppServiceConfig[service.id].update(build_target_id: build_target.id)
    [service, source, build_target]
  end

  def orchestrator(
    fetcher:,
    deployment:,
    dockerfile_builder: FakeBuilder.new(strategy: "dockerfile"),
    buildpack_builder: FakeBuilder.new(strategy: "buildpack"),
    lock: FakeLock.new
  )
    Valpo::Builds::Orchestrator.new(
      source_fetcher: fetcher,
      deployment_lifecycle: deployment,
      builders: {"dockerfile" => dockerfile_builder, "buildpack" => buildpack_builder},
      target_lock: lock
    )
  end

  class FakeFetcher
    attr_reader :ref

    def initialize(dockerfile: true)
      @dockerfile = dockerfile
    end

    def checkout(destination:, ref:, **)
      @ref = ref
      File.write(File.join(destination, "Dockerfile"), "FROM scratch\n") if @dockerfile
      COMMIT
    end
  end

  class FakeBuilder
    attr_reader :arguments

    def initialize(strategy:, error: nil)
      @strategy = strategy
      @error = error
    end

    def initial_metadata(checkout:, build_target: nil)
      if @strategy == "dockerfile"
        {"dockerfile" => File.basename(checkout.dockerfile)}
      else
        {"builder" => "example/builder@sha256:abc", "buildpacks" => [], "processes" => []}
      end
    end

    def build(image:, **arguments)
      @arguments = arguments
      raise @error if @error

      Valpo::Builds::Result.new(image:, strategy: @strategy, metadata: initial_metadata(checkout: arguments.fetch(:checkout)))
    end
  end

  class FakeLock
    attr_reader :ids

    def initialize
      @ids = []
    end

    def synchronize(id)
      ids << id
      yield
    end
  end

  class FakeDeployment
    attr_reader :arguments

    def deploy_built_image(**arguments)
      @arguments = arguments
      :release
    end
  end

  class FakeQueue
    attr_reader :events

    def initialize
      @events = []
    end

    def event(*arguments)
      events << arguments
    end
  end
end
