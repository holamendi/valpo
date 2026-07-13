# frozen_string_literal: true

require "json"
require "rack/test"
require "test_helper"

class ValpoAPIAppTest < Minitest::Test
  include Rack::Test::Methods
  include ValpoTestDatabase

  def app
    Valpo::API::App
  end

  def test_health_and_authentication
    get "/health"
    assert_equal 200, last_response.status
    assert_equal true, json.fetch("ok")

    with_api_token("secret") do
      get "/health"
      assert_equal 401, last_response.status
      header "Authorization", "Bearer secret"
      get "/health"
      assert_equal 200, last_response.status
    end
  end

  def test_system_repair_enqueues_job
    post "/system/repair"

    assert_equal 202, last_response.status
    assert_equal "repair_system", json.fetch("type")
  end

  def test_project_create_list_show_and_empty_delete
    post_json "/projects", name: "hello"
    assert_equal 201, last_response.status
    project = json
    assert_match(/\Aprj_/, project.fetch("id"))

    get "/projects"
    assert_equal ["hello"], json.map { |entry| entry.fetch("name") }
    get "/projects/hello"
    assert_equal project.fetch("id"), json.fetch("id")

    delete "/projects/hello"
    assert_equal 202, last_response.status
    assert_equal "delete_project", json.fetch("type")
  end

  def test_project_delete_refuses_nonempty_project
    project = create_project
    create_app_service(project: project)
    delete "/projects/#{project.id}"
    assert_equal 409, last_response.status
    assert_match "still has services", json.fetch("message")
  end

  def test_create_and_list_app_and_managed_services
    project = create_project
    post_json "/projects/#{project.id}/services", name: "web", type: "web", port: 3000
    assert_equal 201, last_response.status
    web = json.fetch("service")
    assert_equal "web", web.fetch("kind")
    assert_nil json["job"]

    post_json "/projects/#{project.id}/services", name: "database", type: "postgres", version: "17"
    assert_equal 202, last_response.status
    database = json.fetch("service")
    assert_equal "17", database.fetch("managed").fetch("version")
    assert_equal "provision_service", json.fetch("job").fetch("type")

    get "/services?project=hello"
    assert_equal %w[web database].sort, json.map { |entry| entry.fetch("name") }.sort

    get "/projects/hello/services/database"
    assert_equal database.fetch("id"), json.fetch("id")
    get "/projects/#{project.id}/services/#{web.fetch("id")}"
    assert_equal web.fetch("id"), json.fetch("id")
  end

  def test_service_options_are_type_specific
    project = create_project

    post_json "/projects/#{project.id}/services", name: "database", type: "postgres", command: []
    assert_equal 422, last_response.status
    assert_match "command", json.fetch("message")

    post_json "/projects/#{project.id}/services", name: "web-version", type: "web", version: "18"
    assert_equal 422, last_response.status
    assert_match "version", json.fetch("message")

    post_json "/projects/#{project.id}/services", name: "worker", type: "worker", port: 3000
    assert_equal 422, last_response.status
    assert_match "port", json.fetch("message")

    worker = create_app_service(project: project, name: "jobs", kind: "worker")
    post_json "/services/#{worker.id}/deployments", image: "example/worker:v1", healthcheck_path: "/health"
    assert_equal 422, last_response.status
    assert_match "healthcheck", json.fetch("message")

    post_json "/projects/#{project.id}/services", name: "cache", type: "redis", image: "redis:latest"
    assert_equal 422, last_response.status
    assert_match "Unknown service keys: image", json.fetch("message")
  end

  def test_service_identity_endpoints_reject_unsupported_capabilities
    database = create_managed_service
    post_json "/services/#{database.id}/deployments", image: "example/db:v1"
    assert_equal 422, last_response.status
    assert_match "app service", json.fetch("message")

    get "/services/#{database.id}"
    assert_equal "hello/database", json.fetch("reference")
  end

  def test_service_creation_rejects_malformed_commands_and_fractional_ports
    project = create_project
    post_json "/projects/#{project.id}/services", name: "web", type: "web", command: "bin/server"
    assert_equal 422, last_response.status
    assert_match "array", json.fetch("message")

    post_json "/projects/#{project.id}/services", name: "web", type: "web", port: 3000.5
    assert_equal 422, last_response.status
    assert_match "integer", json.fetch("message")
  end

  def test_deploy_release_domain_and_env_endpoints_are_app_scoped
    project = create_project
    app_service = create_app_service(project: project)
    database = create_managed_service(project: project)

    post_json "/services/#{app_service.id}/dependencies", dependency_service_id: database.id
    assert_equal 202, last_response.status
    assert_equal "bind_service", json.fetch("type")
    bind_job = json.fetch("id")
    Valpo::Jobs::Queue.new.lock_next("test-worker")
    Valpo::Jobs::Queue.new.succeed(bind_job, worker_id: "test-worker")

    post_json "/services/#{app_service.id}/deployments", image: "example/app:v1"
    assert_equal 202, last_response.status
    assert_equal app_service.id, json.fetch("payload").fetch("service_id")
    deploy_job = json.fetch("id")
    Valpo::Jobs::Queue.new.lock_next("test-worker")
    Valpo::Jobs::Queue.new.succeed(deploy_job, worker_id: "test-worker")

    post_json "/services/#{app_service.id}/domains", hostname: "hello.example.com"
    assert_equal 201, last_response.status
    assert_equal app_service.id, json.fetch("domain").fetch("service_id")

    get "/services/#{app_service.id}/env"
    assert_equal [], json.fetch("env")
  end

  def test_source_deploy_uses_configured_build_target_and_accepts_ref_override
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id, name: "backend", provider: "github", repository: "acme/backend", ref: "main"
    )
    build_target = Valpo::BuildTarget.create(
      project_id: project.id, source_id: source.id, name: "backend", dockerfile: "Dockerfile", context: "."
    )
    service = create_app_service(project: project)
    Valpo::AppServiceConfig[service.id].update(build_target_id: build_target.id)

    post_json "/services/#{service.id}/deployments", ref: "release"

    assert_equal 202, last_response.status
    assert_equal "deploy_source", json.fetch("type")
    assert_equal "release", json.fetch("payload").fetch("ref")
    refute json.fetch("payload").key?("token")
  end

  def test_source_deploy_requires_build_target_and_rejects_image_with_ref
    service = create_app_service

    post_json "/services/#{service.id}/deployments", {}
    assert_equal 422, last_response.status
    assert_match "build target", json.fetch("message")

    post_json "/services/#{service.id}/deployments", image: "example/app:v1", ref: "main"
    assert_equal 422, last_response.status
    assert_match "cannot be used together", json.fetch("message")
  end

  def test_dependency_endpoint_validates_same_project_at_runtime_and_unbinds
    project = create_project
    app_service = create_app_service(project: project)
    database = create_managed_service(project: project)
    dependency = Valpo::ServiceDependency.create(
      service_id: app_service.id, dependency_service_id: database.id, status: "active", env_json: "{}"
    )
    delete "/services/#{app_service.id}/dependencies/#{database.id}"
    assert_equal 202, last_response.status
    assert_equal dependency.id, Valpo::ServiceDependency[dependency.id].id
  end

  def test_service_delete_requires_force
    service = create_app_service
    delete "/services/#{service.id}"
    assert_equal 422, last_response.status
    delete "/services/#{service.id}?force=true"
    assert_equal 202, last_response.status
    assert_equal "delete_service", json.fetch("type")
  end

  def test_manifest_dry_run_and_apply
    manifest = <<~TOML
      schema = 1

      [project]
      name = "acme"

      [services.web]
      type = "web"
      port = 3000
    TOML
    post_json "/projects/apply", manifest: manifest, dry_run: true
    assert_equal 200, last_response.status
    assert_equal "create", json.fetch("actions").first.fetch("operation")
    assert_nil Valpo::Project.find_by_id_or_name("acme")

    post_json "/projects/apply", manifest: manifest
    assert_equal 202, last_response.status
    assert_equal "apply_project_manifest", json.fetch("type")
  end

  def test_manifest_and_json_validation_errors_are_422
    post_json "/projects/apply", manifest: "schema = 2"
    assert_equal 422, last_response.status
    assert_match "schema", json.fetch("message")

    post "/projects", "{", "CONTENT_TYPE" => "application/json"
    assert_equal 422, last_response.status
    assert_match "valid JSON", json.fetch("message")
  end

  def test_jobs_and_events
    job = Valpo::Jobs::Queue.new.enqueue("system_check", source: "test")
    get "/jobs/#{job.id}"
    assert_equal({"source" => "test"}, json.fetch("payload"))
    get "/jobs/#{job.id}/events"
    assert_equal "Job queued", json.first.fetch("message")
  end

  private

  def json
    JSON.parse(last_response.body)
  end

  def post_json(path, payload)
    post path, JSON.generate(payload), "CONTENT_TYPE" => "application/json"
  end

  def with_api_token(token)
    previous = Valpo.config
    Valpo.config = Valpo::Config.new(
      env: previous.env,
      root: previous.root,
      database_path: previous.database_path,
      api_host: previous.api_host,
      api_port: previous.api_port,
      api_token: token,
      caddy_config_path: previous.caddy_config_path,
      caddy_reload_config_path: previous.caddy_reload_config_path,
      docker_network: previous.docker_network,
      worker_poll_interval: previous.worker_poll_interval,
      app_port_start: previous.app_port_start,
      app_port_end: previous.app_port_end,
      healthcheck_timeout: previous.healthcheck_timeout,
      deploy_drain_delay: previous.deploy_drain_delay
    )
    yield
  ensure
    Valpo.config = previous
    header "Authorization", nil
  end
end
