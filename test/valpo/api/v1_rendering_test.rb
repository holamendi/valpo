# frozen_string_literal: true

require "test_helper"

class ValpoAPIV1ResourceRenderingTest < Minitest::Test
  include ValpoTestDatabase

  def test_project_representation_includes_counts_and_timestamps
    project = create_project
    create_app_service(project:)
    Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend"
    )

    output = Valpo::API::V1::Projects.render(project)
    assert_equal 1, output.fetch(:service_count)
    assert_equal 1, output.fetch(:source_count)
    assert_timestamp output.fetch(:created_at)
    assert output.key?(:manifest_digest)
  end

  def test_source_and_build_target_representations_preserve_configuration
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
      dockerfile: "docker/Dockerfile",
      context: "."
    )

    assert_equal "acme/backend", Valpo::API::V1::Projects.render_source(source).fetch(:repository)
    assert_equal "main", Valpo::API::V1::Projects.render_source(source).fetch(:ref)
    assert_equal "dockerfile", Valpo::API::V1::Projects.render_build_target(build).fetch(:strategy)
    assert_equal "docker/Dockerfile", Valpo::API::V1::Projects.render_build_target(build).fetch(:dockerfile)
    assert_equal source.id, Valpo::API::V1::Projects.render_build_target(build).fetch(:source_id)
  end

  def test_service_representation_includes_app_source_build_dependencies_and_resolved_port
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend"
    )
    build = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "backend",
      dockerfile: "Dockerfile",
      context: "."
    )
    app = create_app_service(project:, command: ["bin/server"])
    Valpo::AppServiceConfig[app.id].update(build_target_id: build.id)
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active",
      env_json: "{}"
    )
    create_release(service: app, status: "active", internal_port: 4000)

    output = Valpo::API::V1::Services.render(app)
    assert_equal "hello", output.fetch(:project)
    assert_equal ["bin/server"], output.dig(:app, :command)
    assert_equal "acme/backend", output.dig(:app, :source, :repository)
    assert_equal "Dockerfile", output.dig(:app, :build, :dockerfile)
    assert_equal 4000, output.dig(:app, :resolved_internal_port)
    assert_equal dependency.id, output.fetch(:dependencies).first.fetch(:id)
  end

  def test_managed_service_and_dependency_representations
    project = create_project
    app = create_app_service(project:)
    database = create_managed_service(project:, version: "17")
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: database.id,
      status: "active",
      env_json: "{}"
    )

    assert_equal "17", Valpo::API::V1::Services.render(database).dig(:managed, :version)
    assert_equal database.id, Valpo::API::V1::Services.render_dependency(dependency).fetch(:dependency_service_id)
  end

  def test_release_domain_and_platform_domain_representations
    platform = create_platform_domain
    service = create_app_service
    release = create_release(
      service:,
      status: "active",
      route_target: "127.0.0.1:20000",
      container_name: "web"
    )
    domain = create_domain(service:, platform_domain_id: platform.id, route_target: release.route_target)

    assert_equal "127.0.0.1:20000", Valpo::API::V1::Services.render_release(release).fetch(:route_target)
    assert_equal platform.id, Valpo::API::V1::Services.render_domain(domain).fetch(:platform_domain_id)
    assert_equal true, Valpo::API::V1::System.render_domain(platform).fetch(:active)
    assert_nil Valpo::API::V1::System.render_domain(nil)
  end

  def test_release_representation_nests_build_metadata
    service = create_app_service
    release = create_release(
      service:,
      source_type: "git",
      build_strategy: "buildpack",
      build_metadata_json: JSON.generate(
        "builder" => "example/builder@sha256:abc",
        "buildpacks" => [{"id" => "paketo-buildpacks/ruby", "version" => "0.1.0"}],
        "processes" => [{"type" => "web", "default" => true}]
      )
    )

    output = Valpo::API::V1::Services.render_release(release)

    assert_equal "buildpack", output.dig(:build, :strategy)
    assert_equal "example/builder@sha256:abc", output.dig(:build, :builder)
    assert_equal "paketo-buildpacks/ruby", output.dig(:build, :buildpacks, 0, "id")
  end

  def test_job_and_job_event_representations_parse_payloads
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check", source: "test")
    queue.event(job.id, "stdout", "hello")
    event = queue.events(job.id).last

    assert_equal({"source" => "test"}, Valpo::API::V1::Jobs.render(job).fetch(:payload))
    assert_equal "hello", Valpo::API::V1::Jobs.render_event(event).fetch(:message)
    assert_timestamp Valpo::API::V1::Jobs.render_event(event).fetch(:created_at)
  end

  private

  def assert_timestamp(value)
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, value)
  end
end
