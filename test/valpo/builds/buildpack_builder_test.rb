# frozen_string_literal: true

require "test_helper"

class ValpoBuildsBuildpackBuilderTest < Minitest::Test
  include ValpoTestDatabase

  def test_builds_and_records_inspected_buildpacks_and_processes
    service = create_app_service
    target = build_target(service.project)
    client = FakeClient.new(
      inspect_result: {
        stdout: JSON.generate(
          "image_name" => "valpo/hello/web:abc",
          "local_info" => {
            "buildpacks" => [{"id" => "paketo-buildpacks/node-engine", "version" => "7.2.1"}],
            "processes" => [
              {"type" => "web", "default" => true},
              {"type" => "task", "default" => false}
            ]
          }
        ),
        stderr: "",
        status: 0,
        success: true
      }
    )
    runner = FakeRunner.new

    result = builder(client:, runner:).build(
      checkout:,
      build_target: target,
      image: "valpo/hello/web:abc",
      service:,
      queue: FakeQueue.new,
      job_id: "job_test"
    )

    assert_equal "buildpack", result.strategy
    assert_equal(
      [{"id" => "paketo-buildpacks/node-engine", "version" => "7.2.1"}],
      result.metadata.fetch("buildpacks")
    )
    assert_equal(
      [{"type" => "web", "default" => true}, {"type" => "task", "default" => false}],
      result.metadata.fetch("processes")
    )
    assert_equal "example/builder@sha256:abc", result.metadata.fetch("builder")
    assert_equal client.command, runner.command
    assert_equal "web", client.command.last.fetch(:default_process)
  end

  def test_worker_requires_an_explicit_runtime_command
    service = create_app_service(name: "jobs", kind: "worker")

    error = assert_raises Valpo::ValidationError do
      builder.build(
        checkout:,
        build_target: build_target(service.project),
        image: "valpo/hello/jobs:abc",
        service:,
        queue: FakeQueue.new,
        job_id: "job_test"
      )
    end

    assert_match "require an explicit command", error.message
  end

  def test_worker_with_a_command_does_not_force_a_web_process
    service = create_app_service(name: "jobs", kind: "worker", command: %w[bundle exec sidekiq])
    client = FakeClient.new

    builder(client:).build(
      checkout:,
      build_target: build_target(service.project),
      image: "valpo/hello/jobs:abc",
      service:,
      queue: FakeQueue.new,
      job_id: "job_test"
    )

    assert_nil client.command.last.fetch(:default_process)
  end

  def test_inspection_failure_keeps_minimal_build_metadata
    service = create_app_service
    queue = FakeQueue.new
    client = FakeClient.new(
      inspect_result: {stdout: "", stderr: "inspect failed", status: 1, success: false}
    )

    result = builder(client:).build(
      checkout:,
      build_target: build_target(service.project),
      image: "valpo/hello/web:abc",
      service:,
      queue:,
      job_id: "job_test"
    )

    assert_equal(
      {"builder" => "example/builder@sha256:abc", "buildpacks" => [], "processes" => []},
      result.metadata
    )
    assert queue.events.any? { it.last.include?("could not inspect buildpack metadata") }
  end

  private

  def builder(client: FakeClient.new, runner: FakeRunner.new)
    Valpo::Builds::BuildpackBuilder.new(
      client:,
      runner:,
      cache_manager: Valpo::Builds::CacheManager.new(docker: nil),
      builder: "example/builder@sha256:abc",
      timeout: 60
    )
  end

  def checkout
    Valpo::Sources::Preflight::Result.new(
      checkout: "/tmp/source",
      strategy: "buildpack",
      dockerfile: nil,
      context: "/tmp/source",
      commit: "a" * 40,
      ref: "HEAD"
    )
  end

  def build_target(project)
    source = Valpo::Source.create(
      project_id: project.id,
      name: "source-#{Valpo::Source.count}",
      provider: "github",
      repository: "acme/backend"
    )
    Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "build-#{Valpo::BuildTarget.count}",
      strategy: "buildpack"
    )
  end

  class FakeClient
    attr_reader :command

    def initialize(inspect_result: {stdout: "{}", stderr: "", status: 0, success: true})
      @inspect_result = inspect_result
    end

    def ensure_supported!
      true
    end

    def build_command(**arguments)
      @command = [:pack, arguments]
    end

    def inspect(_image)
      @inspect_result
    end
  end

  class FakeRunner
    attr_reader :command

    def run(command, **)
      @command = command
      {stdout: "built", stderr: "", status: 0, success: true}
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
