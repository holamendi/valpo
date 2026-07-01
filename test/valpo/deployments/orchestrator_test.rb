# frozen_string_literal: true

require "json"
require "test_helper"
require "valpo/deployments/orchestrator"

class ValpoDeploymentsOrchestratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_successful_deploy_activates_release_and_routes_domains
    project = Valpo::Project.create(name: "hello")
    domain = Valpo::Domain.create(project_id: project.id, hostname: "hello.example.com")
    docker = FakeDocker.new
    caddy = FakeCaddy.new
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
    assert_equal [{ hostname: "hello.example.com", kind: "container", upstream: "127.0.0.1:20000" }], caddy.routes

    run_command = docker.commands.find { |command| command.first == :run }
    assert_equal({ "127.0.0.1:20000" => 3000 }, run_command.fetch(5))
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
    docker = FakeDocker.new(fail_on: :run)
    caddy = FakeCaddy.new
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
    docker = FakeDocker.new
    caddy = FakeCaddy.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("test")

    rolled_back = orchestrator(docker: docker, caddy: caddy).rollback_project(project_id: project.id, queue: queue, job_id: job.id)

    assert_equal previous.id, rolled_back.id
    assert_equal "active", previous.refresh.status
    assert_equal "inactive", current.refresh.status
    assert_equal "127.0.0.1:20000", previous.refresh.route_target
    assert docker.commands.any? { |command| command == [:stop, "current"] }
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
    docker = FakeDocker.new
    caddy = FakeCaddy.new
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

    logs = orchestrator(docker: FakeDocker.new).app_logs(project_id: project.id, tail: 10)

    assert_equal "app log\n", logs.fetch(:stdout)
  end

  private

  def orchestrator(docker:, caddy: FakeCaddy.new, health_checker: FakeHealthChecker.new)
    Valpo::Deployments::Orchestrator.new(
      config: VALPO_TEST_CONFIG,
      docker: docker,
      caddy: caddy,
      health_checker: health_checker
    )
  end

  class FakeDocker
    attr_reader :commands

    def initialize(fail_on: nil)
      @fail_on = fail_on
      @commands = []
    end

    def pull_command(image)
      [:pull, image]
    end

    def image_inspect_command(image)
      [:inspect, image]
    end

    def run_command(name:, image:, network:, labels:, ports:, **)
      [:run, name, image, network, labels, ports]
    end

    def network_create_command(name)
      [:network_create, name]
    end

    def stop_command(name)
      [:stop, name]
    end

    def rm_command(name, force:)
      [:rm, name, force]
    end

    def logs_command(name, tail: nil, **)
      [:logs, name, tail]
    end

    def execute(command)
      @commands << command
      return failure("#{command.first} failed") if command.first == @fail_on

      case command.first
      when :inspect
        success(JSON.generate([{ "RepoDigests" => ["#{command.fetch(1)}@sha256:abc"] }]))
      when :logs
        success("app log\n")
      else
        success("ok\n")
      end
    end

    private

    def success(stdout)
      { stdout: stdout, stderr: "", status: 0, success: true }
    end

    def failure(stderr)
      { stdout: "", stderr: stderr, status: 1, success: false }
    end
  end

  class FakeCaddy
    attr_reader :routes

    def write_config(routes)
      @routes = routes
    end

    def reload_command
      [:reload_caddy]
    end

    def execute(_command)
      { stdout: "reloaded\n", stderr: "", status: 0, success: true }
    end
  end

  class FakeHealthChecker
    def wait(route_target:, path:, timeout:)
      @route_target = route_target
      @path = path
      @timeout = timeout
      true
    end
  end
end
