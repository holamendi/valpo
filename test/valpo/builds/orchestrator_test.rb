# frozen_string_literal: true

require "test_helper"

class ValpoBuildsOrchestratorTest < Minitest::Test
  include ValpoTestDatabase

  COMMIT = "b" * 40

  def test_builds_configured_source_and_deploys_the_commit
    service, source, build_target = configured_service
    fetcher = FakeFetcher.new
    docker = FakeDocker.new
    deployment = FakeDeployment.new

    release = orchestrator(fetcher:, docker:, deployment:).deploy_source(
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
    assert_equal :build, docker.commands.first.first
  end

  def test_failed_build_does_not_touch_the_active_release
    service, source, = configured_service
    service.update(status: "running")
    active = create_release(service:, status: "active")
    deployment = FakeDeployment.new

    error = assert_raises Valpo::ValidationError do
      orchestrator(fetcher: FakeFetcher.new, docker: FakeDocker.new(success: false), deployment:).deploy_source(
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
    assert_nil deployment.arguments
  end

  def test_failed_initial_build_records_a_failed_release_without_activating_it
    service, = configured_service

    assert_raises Valpo::ValidationError do
      orchestrator(fetcher: FakeFetcher.new, docker: FakeDocker.new(success: false), deployment: FakeDeployment.new).deploy_source(
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

  def configured_service
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
      dockerfile: "Dockerfile",
      context: "."
    )
    service = create_app_service(project:)
    Valpo::AppServiceConfig[service.id].update(build_target_id: build_target.id)
    [service, source, build_target]
  end

  def orchestrator(fetcher:, docker:, deployment:)
    Valpo::Builds::Orchestrator.new(
      docker:,
      source_fetcher: fetcher,
      deployment_lifecycle: deployment
    )
  end

  class FakeFetcher
    attr_reader :ref

    def checkout(destination:, ref:, **)
      @ref = ref
      File.write(File.join(destination, "Dockerfile"), "FROM scratch\n")
      COMMIT
    end
  end

  class FakeDocker
    attr_reader :commands

    def initialize(success: true)
      @success = success
      @commands = []
    end

    def build_command(dockerfile:, tag:, context:)
      [:build, dockerfile, tag, context]
    end

    def execute(command)
      commands << command
      {stdout: "build output\n", stderr: (@success ? "" : "build failed\n"), status: (@success ? 0 : 1), success: @success}
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
