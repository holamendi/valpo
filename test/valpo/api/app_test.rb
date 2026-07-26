# frozen_string_literal: true

require "json"
require "openssl"
require "rack/test"
require "test_helper"
require "uri"

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
      assert_equal "unauthorized", json.fetch("error")
      header "Authorization", "Bearer secret"
      get "/health"
      assert_equal 200, last_response.status
    end
  end

  def test_system_repair_enqueues_job
    post "/v1/system/repair"

    assert_equal 202, last_response.status
    assert_equal "repair_system", json.fetch("type")
  end

  def test_project_create_list_show_and_empty_delete
    post_json "/v1/projects", name: "hello"
    assert_equal 201, last_response.status
    project = json
    assert_match(/\Aprj_/, project.fetch("id"))

    get "/v1/projects"
    assert_equal ["hello"], json.map { it.fetch("name") }
    get "/v1/projects/hello"
    assert_equal project.fetch("id"), json.fetch("id")

    delete "/v1/projects/hello"
    assert_equal 202, last_response.status
    assert_equal "delete_project", json.fetch("type")
  end

  def test_project_delete_refuses_nonempty_project
    project = create_project
    create_app_service(project:)
    delete "/v1/projects/#{project.id}"
    assert_equal 409, last_response.status
    assert_equal "conflict", json.fetch("error")
    assert_match "still has services", json.fetch("message")
  end

  def test_create_and_list_app_and_managed_services
    project = create_project
    post_json "/v1/projects/#{project.id}/services", name: "web", type: "web", internal_port: 3000
    assert_equal 201, last_response.status
    web = json.fetch("service")
    assert_equal "web", web.fetch("type")
    refute web.key?("kind")
    assert_nil json["job"]

    post_json "/v1/projects/#{project.id}/services", name: "database", type: "postgres", version: "17"
    assert_equal 202, last_response.status
    database = json.fetch("service")
    assert_equal "17", database.fetch("managed").fetch("version")
    assert_equal "provision_service", json.fetch("job").fetch("type")

    get "/v1/services?project=hello"
    assert_equal %w[web database].sort, json.map { it.fetch("name") }.sort

    get "/v1/projects/hello/services/database"
    assert_equal database.fetch("id"), json.fetch("id")
    get "/v1/projects/#{project.id}/services/#{web.fetch("id")}"
    assert_equal web.fetch("id"), json.fetch("id")
  end

  def test_source_backed_service_creation_enqueues_validation_without_creating_records
    project = create_project
    post_json "/v1/projects/#{project.id}/services",
      name: "web",
      type: "web",
      source: {provider: "github", repository: "acme/backend"},
      build: {},
      deploy: true

    assert_equal 202, last_response.status
    assert_equal "create_source_service", json.fetch("type")
    assert_equal "HEAD", json.dig("payload", "source", "ref")
    assert_equal "auto", json.dig("payload", "build", "strategy")
    assert_nil json.dig("payload", "build", "dockerfile")
    assert_equal true, json.dig("payload", "deploy")
    assert_equal 0, Valpo::Service.where(project_id: project.id).count
    assert_equal 0, Valpo::Source.where(project_id: project.id).count
  end

  def test_source_backed_service_creation_rejects_invalid_configuration_before_enqueue
    project = create_project
    post_json "/v1/projects/#{project.id}/services",
      name: "web",
      type: "web",
      source: {provider: "github", repository: "https://github.com/acme/backend"}

    assert_equal 422, last_response.status
    assert_match "owner/repository", json.fetch("message")
    assert_equal 0, Valpo::Job.count
  end

  def test_service_creation_enforces_source_build_relationships_semantically
    project = create_project

    post_json "/v1/projects/#{project.id}/services",
      name: "web",
      type: "web",
      build: {dockerfile: "Dockerfile"}
    assert_equal 422, last_response.status
    assert_match "build requires source", json.fetch("message")

    post_json "/v1/projects/#{project.id}/services", name: "web", type: "web", deploy: true
    assert_equal 422, last_response.status
    assert_match "deploy requires source", json.fetch("message")

    post_json "/v1/projects/#{project.id}/services",
      name: "database",
      type: "postgres",
      source: {provider: "github", repository: "acme/database"}
    assert_equal 422, last_response.status
    assert_match "source is only valid", json.fetch("message")
  end

  def test_service_options_are_type_specific
    project = create_project

    post_json "/v1/projects/#{project.id}/services", name: "database", type: "postgres", command: []
    assert_equal 422, last_response.status
    assert_match "command", json.fetch("message")

    post_json "/v1/projects/#{project.id}/services", name: "web-version", type: "web", version: "18"
    assert_equal 422, last_response.status
    assert_match "version", json.fetch("message")

    post_json "/v1/projects/#{project.id}/services", name: "worker", type: "worker", internal_port: 3000
    assert_equal 422, last_response.status
    assert_match "port", json.fetch("message")

    worker = create_app_service(project:, name: "jobs", kind: "worker")
    post_json "/v1/services/#{worker.id}/deployments", image: "example/worker:v1", healthcheck_path: "/health"
    assert_equal 422, last_response.status
    assert_match "healthcheck", json.fetch("message")

    post_json "/v1/projects/#{project.id}/services", name: "cache", type: "redis", image: "redis:latest"
    assert_equal 400, last_response.status
    assert_equal "image", json.fetch("details").first.fetch("field")
  end

  def test_service_identity_endpoints_reject_unsupported_capabilities
    database = create_managed_service
    post_json "/v1/services/#{database.id}/deployments", image: "example/db:v1"
    assert_equal 422, last_response.status
    assert_match "app service", json.fetch("message")

    get "/v1/services/#{database.id}"
    assert_equal "hello", json.fetch("project")
    assert_equal "database", json.fetch("name")
  end

  def test_service_creation_rejects_malformed_commands_and_fractional_ports
    project = create_project
    post_json "/v1/projects/#{project.id}/services", name: "web", type: "web", command: "bin/server"
    assert_equal 400, last_response.status
    assert_match "array", json.fetch("details").first.fetch("message")

    post_json "/v1/projects/#{project.id}/services", name: "web", type: "web", internal_port: 3000.5
    assert_equal 400, last_response.status
    assert_match "integer", json.fetch("details").first.fetch("message")
  end

  def test_deploy_release_domain_and_env_endpoints_are_app_scoped
    project = create_project
    app_service = create_app_service(project:)
    database = create_managed_service(project:)

    post_json "/v1/services/#{app_service.id}/dependencies", dependency_service_id: database.id
    assert_equal 202, last_response.status
    assert_equal "bind_service", json.fetch("type")
    bind_job = json.fetch("id")
    Valpo::Jobs::Queue.new.lock_next("test-worker")
    Valpo::Jobs::Queue.new.succeed(bind_job, worker_id: "test-worker")

    post_json "/v1/services/#{app_service.id}/deployments", image: "example/app:v1"
    assert_equal 202, last_response.status
    assert_equal app_service.id, json.fetch("payload").fetch("service_id")
    deploy_job = json.fetch("id")
    Valpo::Jobs::Queue.new.lock_next("test-worker")
    Valpo::Jobs::Queue.new.succeed(deploy_job, worker_id: "test-worker")

    post_json "/v1/services/#{app_service.id}/domains", hostname: "hello.example.com"
    assert_equal 202, last_response.status
    assert_equal app_service.id, json.fetch("domain").fetch("service_id")
    assert_equal "verify_domain", json.fetch("job").fetch("type")

    get "/v1/services/#{app_service.id}/env"
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
    service = create_app_service(project:)
    Valpo::AppServiceConfig[service.id].update(build_target_id: build_target.id)

    post_json "/v1/services/#{service.id}/deployments", ref: "release"

    assert_equal 202, last_response.status
    assert_equal "deploy_source", json.fetch("type")
    assert_equal "release", json.fetch("payload").fetch("ref")
    refute json.fetch("payload").key?("token")
  end

  def test_source_deploy_requires_build_target_and_rejects_image_with_ref
    service = create_app_service

    post_json "/v1/services/#{service.id}/deployments", {}
    assert_equal 422, last_response.status
    assert_match "build target", json.fetch("message")

    post_json "/v1/services/#{service.id}/deployments", image: "example/app:v1", ref: "main"
    assert_equal 422, last_response.status
    assert_match "cannot be used together", json.fetch("message")
  end

  def test_app_service_update_enqueues_normalized_source_and_runtime_changes
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

    patch_json "/v1/services/#{service.id}",
      source: {ref: "release"},
      command: [],
      internal_port: nil,
      healthcheck_path: nil,
      deploy: true

    assert_equal 202, last_response.status
    assert_equal "update_app_service", json.fetch("type")
    assert_equal "release", json.dig("payload", "configuration", "source", "ref")
    assert_nil json.dig("payload", "runtime", "internal_port")
    assert_nil json.dig("payload", "runtime", "healthcheck_path")
    assert_equal [], json.dig("payload", "runtime", "command")
    assert_equal true, json.dig("payload", "deploy")
    assert_equal "main", source.refresh.ref
  end

  def test_service_show_includes_source_build_and_automatic_resolved_port
    project = create_project
    service = Valpo::Sources::ServiceConfigurator.new.create_service!(
      project:,
      service_attributes: {"name" => "web", "type" => "web"},
      source: {"provider" => "github", "repository" => "acme/backend", "ref" => "HEAD"},
      build: {"strategy" => "dockerfile", "dockerfile" => "Dockerfile", "context" => "."}
    )
    create_release(service:, status: "active", internal_port: 3000)

    get "/v1/services/#{service.id}"

    assert_equal 200, last_response.status
    assert_equal "acme/backend", json.dig("app", "source", "repository")
    assert_equal "HEAD", json.dig("app", "source", "ref")
    assert_equal "connected", json.dig("app", "source", "status")
    assert_equal "Dockerfile", json.dig("app", "build", "dockerfile")
    assert_equal "automatic", json.dig("app", "port_mode")
    assert_equal 3000, json.dig("app", "resolved_internal_port")
  end

  def test_dependency_endpoint_validates_same_project_at_runtime_and_unbinds
    project = create_project
    app_service = create_app_service(project:)
    database = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app_service.id, dependency_service_id: database.id, status: "active", env_json: "{}"
    )
    delete "/v1/services/#{app_service.id}/dependencies/#{database.id}"
    assert_equal 202, last_response.status
    assert_equal dependency.id, Valpo::ServiceDependency[dependency.id].id
  end

  def test_service_delete_requires_force
    service = create_app_service
    delete "/v1/services/#{service.id}?force=1"
    assert_equal 400, last_response.status
    assert_equal "invalid_request", json.fetch("error")

    delete "/v1/services/#{service.id}"
    assert_equal 422, last_response.status
    assert_equal "validation_failed", json.fetch("error")
    delete "/v1/services/#{service.id}?force=true"
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
    post_json "/v1/projects/apply", manifest:, dry_run: true
    assert_equal 200, last_response.status
    assert_equal "create", json.fetch("actions").first.fetch("operation")
    assert_nil Valpo::Project.find_by_id_or_name("acme")

    post_json("/v1/projects/apply", manifest:)
    assert_equal 202, last_response.status
    assert_equal "apply_project_manifest", json.fetch("type")
  end

  def test_manifest_errors_are_422_and_json_errors_are_400
    post_json "/v1/projects/apply", manifest: "schema = 2"
    assert_equal 422, last_response.status
    assert_equal "validation_failed", json.fetch("error")
    assert_match "schema", json.fetch("message")

    post "/v1/projects", "{", "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
    assert_match "valid JSON", json.fetch("message")
  end

  def test_unexpected_errors_are_logged_but_return_a_generic_500
    job = Valpo::Jobs::Queue.new.enqueue("system_check")
    job.update(payload_json: "{")

    _stdout, stderr = capture_io { get "/v1/jobs/#{job.id}" }

    assert_equal 500, last_response.status
    assert_equal "internal_error", json.fetch("error")
    assert_equal "An internal error occurred", json.fetch("message")
    assert_match "JSON::ParserError", stderr
    refute_includes last_response.body, "unexpected end"
  end

  def test_request_contract_rejects_non_object_missing_and_unknown_json
    post "/v1/projects", "[]", "CONTENT_TYPE" => "application/json"
    assert_invalid_request("Request body must be a JSON object")

    post "/v1/projects", JSON.generate("hello"), "CONTENT_TYPE" => "application/json"
    assert_invalid_request("Request body must be a JSON object")

    post "/v1/projects", JSON.generate({}), "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
    assert_equal "name", json.fetch("details").first.fetch("field")

    post_json "/v1/projects", name: "hello", unexpected: true
    assert_equal 400, last_response.status
    assert_equal "unexpected", json.fetch("details").first.fetch("field")
  end

  def test_request_contract_rejects_unknown_nested_keys_and_non_native_types
    project = create_project
    post_json "/v1/projects/#{project.id}/services",
      name: "web",
      type: "web",
      deploy: "false",
      source: {provider: "github", repository: "acme/web", token: "secret"}

    assert_equal 400, last_response.status
    fields = json.fetch("details").map { it.fetch("field") }
    assert_includes fields, "deploy"
    assert_includes fields, "source.token"

    post_json "/v1/projects/#{project.id}/services", name: "web", type: "web", port: 3000
    assert_equal 400, last_response.status
    assert_equal "port", json.fetch("details").first.fetch("field")
  end

  def test_query_contracts_reject_unknown_keys_and_non_literal_booleans
    service = create_app_service
    get "/v1/services/#{service.id}/env?reveal=1"
    assert_equal 400, last_response.status
    assert_equal "invalid_request", json.fetch("error")

    get "/v1/services?unknown=value"
    assert_equal 400, last_response.status
    assert_equal "unknown", json.fetch("details").first.fetch("field")

    get "/health?verbose=true"
    assert_equal 400, last_response.status

    get "/?verbose=true"
    assert_equal 400, last_response.status
  end

  def test_v1_routes_are_exact_and_old_routes_are_removed
    project = create_project
    service = create_app_service(project:)
    job = Valpo::Jobs::Queue.new.enqueue("system_check")

    %w[/projects /services /jobs /system/repair].each do
      get it
      assert_json_not_found(it)
    end

    [
      "/health/extra",
      "/v1/projects/#{project.id}/extra",
      "/v1/services/#{service.id}/logs/extra",
      "/v1/jobs/#{job.id}/events/extra",
      "/v1/unknown"
    ].each do
      get it
      assert_json_not_found(it)
    end

    put "/v1/projects", JSON.generate(name: "nope"), "CONTENT_TYPE" => "application/json"
    assert_json_not_found("PUT /v1/projects")
  end

  def test_jobs_and_events
    job = Valpo::Jobs::Queue.new.enqueue("system_check", source: "test")
    get "/v1/jobs/#{job.id}"
    assert_equal({"source" => "test"}, json.fetch("payload"))
    get "/v1/jobs/#{job.id}/events"
    assert_equal "Job queued", json.first.fetch("message")
  end

  def test_job_and_event_lists_are_bounded_and_cursor_paginated
    queue = Valpo::Jobs::Queue.new
    105.times { queue.enqueue("system_check") }

    get "/v1/jobs"
    assert_equal 100, json.length
    get "/v1/jobs?limit=105"
    assert_equal 105, json.length
    get "/v1/jobs?limit=501"
    assert_equal 400, last_response.status
    assert_equal "limit", json.fetch("details").first.fetch("field")

    job = queue.list(limit: 1).first
    205.times { queue.event(job.id, "stdout", "event #{it}") }
    get "/v1/jobs/#{job.id}/events"
    first_page = json
    assert_equal 200, first_page.length

    all_events = queue.events(job.id, limit: 500)
    cursor_id = first_page.last.fetch("id")
    expected_next_id = all_events.fetch(all_events.index { it.id == cursor_id } + 1).id
    get "/v1/jobs/#{job.id}/events?after=#{cursor_id}"
    assert_equal 6, json.length
    assert_equal expected_next_id, json.first.fetch("id")
  end

  def test_event_cursor_must_belong_to_the_requested_job
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    other = queue.enqueue("system_check")
    cursor = queue.events(other.id).first

    get "/v1/jobs/#{job.id}/events?after=#{cursor.id}"

    assert_equal 422, last_response.status
    assert_match "cursor does not belong", json.fetch("message")
  end

  def test_platform_app_domain_is_configured_after_install
    put "/v1/system/app-domain", JSON.generate(hostname: "apps.example.com"), "CONTENT_TYPE" => "application/json"

    assert_equal 202, last_response.status, last_response.body
    assert_equal "apps.example.com", json.dig("app_domain", "hostname")
    assert_equal "pending", json.dig("app_domain", "status")
    assert_equal "verify_platform_domain", json.dig("job", "type")

    get "/v1/system/app-domain"
    assert_nil json["active"]
    assert_equal "apps.example.com", json.dig("candidate", "hostname")
  end

  def test_github_app_setup_uses_a_public_one_time_url_while_control_api_stays_authenticated
    create_platform_domain

    with_api_token("secret") do
      post_json "/v1/auth/github", {}
      assert_equal 401, last_response.status

      header "Authorization", "Bearer secret"
      post_json "/v1/auth/github", organization: "acme"
      assert_equal 201, last_response.status
      setup_uri = URI(json.fetch("setup_url"))
      assert_equal "github.apps.example.com", setup_uri.host

      header "Authorization", nil
      get setup_uri.request_uri
      assert_equal 200, last_response.status
      assert_equal "text/html", last_response.media_type
      assert_includes last_response.body, "https://github.com/organizations/acme/settings/apps/new"
      assert_includes last_response.body, "github.apps.example.com/integrations/github/webhook"
      assert_equal "no-store", last_response.headers.fetch("Cache-Control")
      assert_equal "no-referrer", last_response.headers.fetch("Referrer-Policy")

      get "/v1/auth/github"
      assert_equal 401, last_response.status
    end
  end

  def test_github_webhook_rejects_unsigned_requests_without_api_authentication
    with_api_token("secret") do
      post "/integrations/github/webhook", "{}", "CONTENT_TYPE" => "application/json"

      assert_equal 401, last_response.status
      assert_equal "Invalid GitHub webhook signature", json.fetch("message")
    end
  end

  def test_github_webhook_rejects_payloads_over_25_mib_before_signature_validation
    post "/integrations/github/webhook", "{}", {
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => (Valpo::API::App::GITHUB_WEBHOOK_MAX_BYTES + 1).to_s
    }

    assert_equal 413, last_response.status
    assert_equal "payload_too_large", json.fetch("error")
  end

  def test_github_webhook_bounded_read_rejects_an_oversized_body_with_a_misleading_length
    limit = Valpo::API::App::GITHUB_WEBHOOK_MAX_BYTES
    post "/integrations/github/webhook", "x" * (limit + 1), {
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => limit.to_s
    }

    assert_equal 413, last_response.status
    assert_equal "payload_too_large", json.fetch("error")
  end

  def test_github_integration_homepage_is_public_but_does_not_expose_control_state
    with_api_token("secret") do
      get "/integrations/github"

      assert_equal 200, last_response.status
      assert_equal "text/html", last_response.media_type
      assert_includes last_response.body, "signed webhooks"
      refute_includes last_response.body, "app_id"
    end
  end

  def test_github_webhook_accepts_a_signed_ping_without_api_authentication
    credentials = Valpo::GitHub::Credentials.new(Valpo.config.github_app_credentials_path)
    credentials.write(
      "app_id" => "123",
      "app_domain" => "apps.example.com",
      "client_id" => "Iv1.client",
      "owner" => "octocat",
      "slug" => "valpo-test",
      "pem" => OpenSSL::PKey::RSA.generate(1024).to_pem,
      "webhook_secret" => "hook-secret"
    )
    body = JSON.generate("zen" => "Keep it logically awesome.")
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "hook-secret", body)}"

    with_api_token("secret") do
      post "/integrations/github/webhook", body, {
        "CONTENT_TYPE" => "application/json",
        "HTTP_X_GITHUB_EVENT" => "ping",
        "HTTP_X_GITHUB_DELIVERY" => "delivery-ping",
        "HTTP_X_HUB_SIGNATURE_256" => signature
      }

      assert_equal 202, last_response.status
      assert_equal false, json.fetch("duplicate")
      assert_equal [], json.fetch("jobs")
    end
  ensure
    credentials&.delete
  end

  def test_running_web_service_keeps_its_last_verified_domain
    service = create_app_service(status: "running")
    release = create_release(service:, status: "active", route_target: "127.0.0.1:20000")
    domain = create_domain(service:)

    delete "/v1/services/#{service.id}/domains/#{domain.id}"
    assert_equal 409, last_response.status
    assert_match "Stop the web service", json.fetch("message")

    service.update(status: "stopped")
    delete "/v1/services/#{service.id}/domains/#{domain.id}"
    assert_equal 200, last_response.status
    assert_equal true, json.fetch("deleted")
    assert_equal "ready", release.refresh.status
  end

  private

  def json
    JSON.parse(last_response.body)
  end

  def post_json(path, payload)
    post path, JSON.generate(payload), "CONTENT_TYPE" => "application/json"
  end

  def patch_json(path, payload)
    patch path, JSON.generate(payload), "CONTENT_TYPE" => "application/json"
  end

  def assert_invalid_request(message)
    assert_equal 400, last_response.status
    assert_equal "invalid_request", json.fetch("error")
    assert_equal message, json.fetch("message")
  end

  def assert_json_not_found(label)
    assert_equal 404, last_response.status, label
    assert_equal "application/json", last_response.media_type, label
    assert_equal "not_found", json.fetch("error"), label
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
