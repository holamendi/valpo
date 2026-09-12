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

    output = Valpo::API::V1::Serializers::Project.render(project)
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

    assert_equal "acme/backend", Valpo::API::V1::Serializers::Source.render(source).fetch(:repository)
    assert_equal "main", Valpo::API::V1::Serializers::Source.render(source).fetch(:ref)
    assert_equal "dockerfile", Valpo::API::V1::Serializers::BuildTarget.render(build).fetch(:strategy)
    assert_equal "docker/Dockerfile", Valpo::API::V1::Serializers::BuildTarget.render(build).fetch(:dockerfile)
    assert_equal source.id, Valpo::API::V1::Serializers::BuildTarget.render(build).fetch(:source_id)
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
      status: "active"
    )
    create_release(service: app, status: "active", internal_port: 4000)

    output = Valpo::API::V1::Serializers::Service.render(app)
    assert_equal "hello", output.fetch(:project)
    assert_equal "web", output.fetch(:type)
    refute output.key?(:kind)
    refute output.key?(:managed)
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
      status: "active"
    )

    output = Valpo::API::V1::Serializers::Service.render(database)
    refute output.key?(:app)
    managed = output.fetch(:managed)
    assert_equal "17", managed.fetch(:version)
    refute managed.key?(:plan)
    assert_equal database.id, Valpo::API::V1::Serializers::ServiceDependency.render(dependency).fetch(:dependency_service_id)
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

    assert_equal "127.0.0.1:20000", Valpo::API::V1::Serializers::Release.render(release).fetch(:route_target)
    assert_equal platform.id, Valpo::API::V1::Serializers::Domain.render(domain).fetch(:platform_domain_id)
    assert_equal true, Valpo::API::V1::Serializers::PlatformDomain.render(platform).fetch(:active)
    assert_nil Valpo::API::V1::Serializers::PlatformDomain.render(nil)
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

    output = Valpo::API::V1::Serializers::Release.render(release)

    assert_equal "buildpack", output.dig(:build, :strategy)
    assert_equal "example/builder@sha256:abc", output.dig(:build, :builder)
    assert_equal "paketo-buildpacks/ruby", output.dig(:build, :buildpacks, 0, "id")
  end

  def test_job_and_job_event_representations_parse_payloads
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check", source: "test")
    queue.event(job.id, "stdout", "hello")
    event = queue.events(job.id).last

    assert_equal({"source" => "test"}, Valpo::API::V1::Serializers::Job.render(job).fetch(:payload))
    assert_equal "hello", Valpo::API::V1::Serializers::JobEvent.render(event).fetch(:message)
    assert_timestamp Valpo::API::V1::Serializers::JobEvent.render(event).fetch(:created_at)
  end

  def test_app_representation_keeps_null_optional_configuration
    app = create_app_service(port: nil)
    output = Valpo::API::V1::Serializers::Service.render(app)
    config = output.fetch(:app)

    assert_nil config.fetch(:source)
    assert_nil config.fetch(:build)
    assert_nil config.fetch(:resolved_internal_port)
    assert_equal "automatic", config.fetch(:port_mode)
    assert_equal [], output.fetch(:dependencies)
  end

  def test_release_build_preserves_missing_and_explicit_null_metadata
    release = create_release(service: create_app_service)
    assert_nil Valpo::API::V1::Serializers::Release.render(release).fetch(:build)

    release.update(build_strategy: "dockerfile", build_metadata_json: JSON.generate(
      "dockerfile" => "Dockerfile", "builder" => nil, "private_detail" => "hidden"
    ))
    assert_equal({strategy: "dockerfile", dockerfile: "Dockerfile", builder: nil},
      Valpo::API::V1::Serializers::Release.render(release).fetch(:build))
  end

  def test_environment_variable_is_redacted_by_default_and_can_be_explicitly_revealed
    variable = Valpo::ServiceEnvironmentVariable.new(
      service_id: create_app_service.id, name: "API_KEY", sensitive: true
    )
    variable.value = "secret"
    variable.save
    serializer = Valpo::API::V1::Serializers::EnvironmentVariable

    variable.stub(:value, -> { raise "Redacted secrets must not be decrypted" }) do
      output = serializer.render(variable)
      assert_equal "********", output.fetch(:value)
      assert output.fetch(:redacted)
      refute output.key?(:value_ciphertext)
    end
    output = serializer.render(variable, reveal: true)
    assert_equal "secret", output.fetch(:value)
    refute output.fetch(:redacted)

    variable.sensitive = false
    output = serializer.render(variable)
    assert_equal "secret", output.fetch(:value)
    refute output.fetch(:redacted)
  end

  def test_api_credential_representation_excludes_stored_secrets
    credential, = Valpo::APICredential.issue(name: "serializer", scopes: %w[read])
    output = Valpo::API::V1::Serializers::APICredential.render(credential)

    assert_equal %w[read], output.fetch(:scopes)
    refute output.key?(:token_digest)
    refute output.key?(:token)
    assert_timestamp output.fetch(:created_at)
  end

  private

  def assert_timestamp(value)
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, value)
  end
end
