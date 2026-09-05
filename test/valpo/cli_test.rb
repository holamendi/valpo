# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"
require "test_helper"

class ValpoCLITest < Minitest::Test
  def test_help_works_offline_at_every_level_and_hides_jobs_at_root
    client = FakeAPIClient.new(Valpo::API::Client::Error.new("must not connect"))

    [
      [%w[--help], "project"],
      [%w[help], "service"],
      [%w[project --help], "create"],
      [%w[help project], "logs"],
      [%w[service create --help], "Postgres 16, 17, or 18"],
      [%w[help service create], "Redis 7 or 8"]
    ].each do |arguments, expected|
      status, stdout, stderr = run_cli(client, arguments)
      assert_equal 0, status
      assert_includes stdout, expected
      assert_empty stderr
    end

    _status, root_help, = run_cli(client, %w[--help])
    refute_match(/^\s+job\s/, root_help)
    assert_empty client.requests
  end

  def test_unknown_command_and_invalid_option_exit_two_with_no_stdout
    client = FakeAPIClient.new([])
    status, stdout, stderr = run_cli(client, %w[servce list])
    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "Did you mean"

    status, stdout, stderr = run_cli(client, %w[service list --wat])
    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "called with arguments"
    assert_includes stderr, "--help` for usage"
  end

  def test_version_is_json_and_offline_even_with_invalid_api_url
    status, stdout, stderr = run_cli(FakeAPIClient.new([]), %w[version --json --api-url not-a-url])
    assert_equal 0, status
    assert_equal({"version" => Valpo::VERSION}, JSON.parse(stdout))
    assert_empty stderr
  end

  def test_system_status_reports_release_and_schema_compatibility
    health = {
      "ok" => true,
      "version" => "0.2.0",
      "api_version" => Valpo::API_VERSION,
      "schema_version" => 2,
      "schema_target" => 2,
      "config_schema" => 1,
      "host_profile" => 1,
      "channel" => "preview",
      "artifact_digest" => "sha256:#{"a" * 64}"
    }
    client = FakeAPIClient.new(health)

    status, stdout, stderr = run_cli(client, %w[system status --json])

    assert_equal 0, status
    output = JSON.parse(stdout)
    assert_equal Valpo::VERSION, output.fetch("client_version")
    assert_equal "0.2.0", output.fetch("server_version")
    assert_equal Valpo::API_VERSION, output.fetch("client_api_version")
    assert_equal Valpo::API_VERSION, output.fetch("server_api_version")
    assert_equal 2, output.fetch("schema_version")
    assert_equal 2, output.fetch("schema_target")
    assert_equal 1, output.fetch("config_schema")
    assert_equal 1, output.fetch("host_profile")
    assert_equal "preview", output.fetch("channel")
    assert_equal "sha256:#{"a" * 64}", output.fetch("artifact_digest")
    assert_equal true, output.fetch("compatible")
    assert_empty stderr
    assert_equal({method: :get, path: "/health", payload: nil, query: nil}, client.requests.first)
  end

  def test_system_status_warns_when_api_versions_are_incompatible
    health = {
      "ok" => true,
      "version" => Valpo::VERSION,
      "api_version" => Valpo::API_VERSION + 1,
      "schema_version" => 1,
      "schema_target" => 1,
      "config_schema" => 1,
      "host_profile" => 1,
      "channel" => "development",
      "artifact_digest" => nil
    }

    status, stdout, stderr = run_cli(FakeAPIClient.new(health), %w[system status --json])

    assert_equal 0, status
    assert_equal false, JSON.parse(stdout).fetch("compatible")
    assert_includes stderr, "client API 1 is not compatible with server API 2"
  end

  def test_system_maintenance_sends_dry_run_and_can_return_without_waiting
    client = FakeAPIClient.new("id" => job_id, "status" => "queued")

    status, stdout, stderr = run_cli(client, %w[system maintenance --dry-run --no-wait --json])

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).fetch("id")
    assert_empty stderr
    request = client.requests.first
    assert_equal :post, request.fetch(:method)
    assert_equal "/v1/system/maintenance", request.fetch(:path)
    assert_equal({"dry_run" => true}, request.fetch(:payload))
  end

  def test_system_secret_commands_enqueue_without_secret_payloads
    client = FakeAPIClient.new([
      {"id" => job_id, "status" => "queued"},
      {"id" => job_id, "status" => "queued"}
    ])

    verify_status, verify_stdout, verify_stderr = run_cli(
      client,
      %w[system secrets verify --no-wait --json]
    )
    rotate_status, rotate_stdout, rotate_stderr = run_cli(
      client,
      %w[system secrets rotate --no-wait --json]
    )

    assert_equal 0, verify_status
    assert_equal 0, rotate_status
    assert_equal job_id, JSON.parse(verify_stdout).fetch("id")
    assert_equal job_id, JSON.parse(rotate_stdout).fetch("id")
    assert_empty verify_stderr
    assert_empty rotate_stderr
    assert_equal(
      [
        {method: :post, path: "/v1/system/secrets/verify", payload: nil, query: nil},
        {method: :post, path: "/v1/system/secrets/rotate", payload: nil, query: nil}
      ],
      client.requests
    )
  end

  def test_create_service_documents_and_rejects_incompatible_options_locally
    client = FakeAPIClient.new([])
    status, _stdout, stderr = run_cli(client, %w[service create database --project acme --type postgres --port 3000])
    assert_equal 2, status
    assert_includes stderr, "--port is not valid for postgres"

    status, _stdout, stderr = run_cli(client, %w[service create web --project acme --type web --version 18])
    assert_equal 2, status
    assert_includes stderr, "--version is not valid"
    assert_empty client.requests
  end

  def test_create_service_uses_project_collection_and_no_wait_returns_queued_job
    job = {"id" => job_id, "status" => "queued"}
    client = FakeAPIClient.new("service" => {"id" => service_id}, "job" => job)
    status, stdout, stderr = run_cli(client, %w[service create database --project acme --type postgres --version 17 --no-wait --json])

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).fetch("job").fetch("id")
    assert_empty stderr
    request = client.requests.first
    assert_equal :post, request.fetch(:method)
    assert_equal "/v1/projects/acme/services", request.fetch(:path)
    assert_equal "database", request.fetch(:payload).fetch("name")
    assert_equal "17", request.fetch(:payload).fetch("version")
    assert_equal 1, client.requests.length
  end

  def test_create_source_service_sends_defaults_and_deploy_flag
    queued = {"id" => job_id, "status" => "queued"}
    client = FakeAPIClient.new(queued)
    status, stdout, stderr = run_cli(
      client,
      %w[service create web --project acme --type web --source github:holamendi/smol-roda --deploy --no-wait --json]
    )

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).fetch("id")
    assert_empty stderr
    payload = client.requests.first.fetch(:payload)
    assert_equal({"provider" => "github", "repository" => "holamendi/smol-roda", "ref" => "HEAD"}, payload.fetch("source"))
    assert_equal({}, payload.fetch("build"))
    assert_equal true, payload.fetch("deploy")
    refute payload.key?("internal_port")
  end

  def test_create_source_service_waits_and_emits_service_and_job_as_one_document
    queued = {"id" => job_id, "status" => "queued"}
    succeeded = {"id" => job_id, "status" => "succeeded", "progress" => 100}
    service = {"id" => service_id, "project" => "acme", "name" => "web", "type" => "web", "status" => "created", "app" => {}, "dependencies" => []}
    client = FakeAPIClient.new([queued, [], queued, [], succeeded, [], service])

    status, stdout, stderr = run_cli(
      client,
      %w[service create web --project acme --type web --source github:acme/web --json]
    )

    assert_equal 0, status
    output = JSON.parse(stdout)
    assert_equal service_id, output.dig("service", "id")
    assert_equal "succeeded", output.dig("job", "status")
    assert_includes client.requests.map { it.fetch(:path) }, "/v1/projects/acme/services/web"
    assert_empty stderr
  end

  def test_update_service_sends_partial_source_and_clear_options
    queued = {"id" => job_id, "status" => "queued"}
    client = FakeAPIClient.new([{"id" => service_id}, queued])
    status, stdout, = run_cli(
      client,
      %w[service update web --project acme --ref release --clear-port --clear-healthcheck --deploy --no-wait --json]
    )

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).fetch("id")
    request = client.requests.last
    assert_equal :patch, request.fetch(:method)
    assert_equal({"ref" => "release"}, request.dig(:payload, "source"))
    assert_nil request.dig(:payload, "internal_port")
    assert_nil request.dig(:payload, "healthcheck_path")
    assert_equal true, request.dig(:payload, "deploy")
  end

  def test_source_options_require_a_valid_source_spec
    client = FakeAPIClient.new([])
    status, _stdout, stderr = run_cli(client, %w[service create web --project acme --type web --source wat])
    assert_equal 2, status
    assert_includes stderr, "PROVIDER:OWNER/REPOSITORY"

    status, _stdout, stderr = run_cli(client, %w[service create web --project acme --type web --ref main])
    assert_equal 2, status
    assert_includes stderr, "require --source"
    assert_empty client.requests
  end

  def test_service_reference_uses_exact_lookup_and_is_cached
    database_id = "svc_01900000000070008000000000000001"
    client = FakeAPIClient.new([
      {"id" => service_id, "name" => "web"},
      {"id" => database_id, "name" => "database"},
      {"id" => job_id, "status" => "queued"}
    ])
    status, = run_cli(client, %w[service bind web database --project acme --no-wait --json])

    assert_equal 0, status
    assert_equal [
      "/v1/projects/acme/services/web",
      "/v1/projects/acme/services/database",
      "/v1/services/#{service_id}/dependencies"
    ], client.requests.map { it.fetch(:path) }

    cache_client = FakeAPIClient.new("id" => service_id)
    resolver = Valpo::CLI::ReferenceResolver.new(client: cache_client)
    2.times { assert_equal service_id, resolver.service_id("web", project: "acme") }
    assert_equal 1, cache_client.requests.count { it.fetch(:path) == "/v1/projects/acme/services/web" }
  end

  def test_typed_service_id_skips_resolution
    client = FakeAPIClient.new("id" => service_id, "project" => "acme", "name" => "web", "type" => "web", "status" => "created", "app" => {}, "dependencies" => [])
    status, = run_cli(client, ["service", "show", service_id, "--json"])
    assert_equal 0, status
    assert_equal ["/v1/services/#{service_id}"], client.requests.map { it.fetch(:path) }
  end

  def test_set_default_domain_uses_runtime_configuration_endpoint
    job = {"id" => job_id, "status" => "queued"}
    app_domain = {"hostname" => "apps.example.com", "status" => "pending"}
    client = FakeAPIClient.new("app_domain" => app_domain, "job" => job)

    status, stdout, stderr = run_cli(client, %w[domain set-default apps.example.com --no-wait --json])

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).dig("job", "id")
    assert_empty stderr
    assert_equal :put, client.requests.first.fetch(:method)
    assert_equal "/v1/system/app-domain", client.requests.first.fetch(:path)
    assert_equal({"hostname" => "apps.example.com"}, client.requests.first.fetch(:payload))
  end

  def test_named_service_requires_project_and_slash_references_are_rejected
    client = FakeAPIClient.new([])

    status, stdout, stderr = run_cli(client, %w[service show web])
    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "--project is required"

    status, stdout, stderr = run_cli(client, %w[service show acme/web --project acme])
    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "must not contain /"
    assert_empty client.requests
  end

  def test_operations_wait_by_default_stream_unseen_events_and_emit_one_json_document
    queued = {"id" => job_id, "status" => "queued"}
    event = {"id" => event_id, "stream" => "system", "message" => "Deploy started"}
    finished_event = {"id" => "evt_01900000000070008000000000000001", "stream" => "stdout", "message" => "healthy"}
    client = FakeAPIClient.new([
      {"id" => service_id},
      queued,
      [event],
      queued,
      [finished_event],
      {"id" => job_id, "status" => "succeeded", "progress" => 100},
      []
    ])
    status, stdout, stderr = run_cli(client, %w[service deploy web --project acme --image nginx:alpine --json])

    assert_equal 0, status
    assert_equal "succeeded", JSON.parse(stdout).fetch("status")
    assert_equal 1, stderr.scan("Deploy started").length
    assert_equal 1, stderr.scan("healthy").length
    assert_equal 3, client.requests.count { it.fetch(:path).end_with?("/events") }
    event_queries = client.requests.filter_map { it.fetch(:query) if it.fetch(:path).end_with?("/events") }
    assert_equal [
      {"limit" => 500},
      {"limit" => 500, "after" => event_id},
      {"limit" => 500, "after" => finished_event.fetch("id")}
    ], event_queries
  end

  def test_source_deploy_sends_ref_without_requiring_an_image
    client = FakeAPIClient.new([
      {"id" => service_id},
      {"id" => job_id, "status" => "queued"}
    ])

    status, = run_cli(client, %w[service deploy web --project acme --ref release --no-wait --json])

    assert_equal 0, status
    request = client.requests.last
    assert_equal({"ref" => "release"}, request.fetch(:payload))
  end

  def test_auth_login_reads_token_stdin_and_stores_it_through_the_api
    client = FakeAPIClient.new(
      "authenticated" => true,
      "provider" => "github",
      "mode" => "pat",
      "account" => "octocat"
    )
    status, stdout, stderr = run_cli(
      client,
      ["auth", "login", "github", "--with-token", "--json"],
      input: StringIO.new("github_pat_secret\n")
    )

    assert_equal 0, status
    assert_equal true, JSON.parse(stdout).fetch("authenticated")
    assert_equal "octocat", JSON.parse(stdout).fetch("account")
    assert_equal "/v1/auth/github/pat", client.requests.first.fetch(:path)
    assert_equal "github_pat_secret", client.requests.first.fetch(:payload).fetch("token")
    refute_includes stdout, "github_pat_secret"
    refute_includes stderr, "github_pat_secret"
  end

  def test_auth_login_rejects_a_positional_secret_without_echoing_it
    status, stdout, stderr = run_cli(
      FakeAPIClient.new([]),
      %w[auth login github github_pat_secret],
      input: StringIO.new
    )

    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "not as arguments"
    refute_includes stderr, "github_pat_secret"
  end

  def test_auth_status_and_logout_use_server_side_credentials
    status, stdout, = run_cli(
      FakeAPIClient.new("authenticated" => true, "provider" => "github", "mode" => "pat"),
      ["auth", "status", "github", "--json"]
    )
    assert_equal 0, status
    assert_equal true, JSON.parse(stdout).fetch("authenticated")

    status, stdout, = run_cli(
      FakeAPIClient.new("authenticated" => false, "provider" => "github", "removed" => true),
      ["auth", "logout", "github", "--json"]
    )
    assert_equal 0, status
    assert_equal true, JSON.parse(stdout).fetch("removed")
  end

  def test_auth_login_prints_the_one_time_github_app_setup_url
    setup_url = "https://github.apps.example.com/integrations/github/setup?token=one-time"
    client = FakeAPIClient.new("setup_url" => setup_url, "expires_at" => "2026-07-26T13:00:00Z")

    status, stdout, stderr = run_cli(client, %w[auth login github --organization acme])

    assert_equal 0, status
    assert_includes stdout, "create and install the GitHub App"
    assert_includes stdout, setup_url
    assert_empty stderr
    assert_equal :post, client.requests.first.fetch(:method)
    assert_equal "/v1/auth/github", client.requests.first.fetch(:path)
    assert_equal({"organization" => "acme"}, client.requests.first.fetch(:payload))
  end

  def test_auth_login_does_not_store_a_token_rejected_by_github
    validator = FakeGitHubValidator.new(error: Valpo::ValidationError.new("GitHub rejected the PAT"))
    client = FakeAPIClient.new([])

    status, stdout, stderr = run_cli(
      client,
      ["auth", "login", "github", "--with-token"],
      input: StringIO.new("github_pat_invalid\n"),
      github_validator: validator
    )

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "GitHub rejected"
    assert_empty client.requests
    refute_includes stderr, "github_pat_invalid"
  end

  def test_service_environment_set_reads_stdin_and_never_uses_a_value_argument
    response = {
      "variable" => {"id" => "env_1", "name" => "API_KEY", "value" => "********"},
      "job" => {"id" => job_id, "status" => "queued"}
    }
    client = FakeAPIClient.new(response)

    status, stdout, stderr = run_cli(
      client,
      ["service", "env", "set", service_id, "API_KEY", "--no-wait", "--json"],
      input: StringIO.new("secret-value\n")
    )

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).dig("job", "id")
    request = client.requests.first
    assert_equal :put, request.fetch(:method)
    assert_equal "/v1/services/#{service_id}/env/API_KEY", request.fetch(:path)
    assert_equal({"value" => "secret-value", "sensitive" => true}, request.fetch(:payload))
    refute_includes stdout, "secret-value"
    refute_includes stderr, "secret-value"
  end

  def test_api_token_create_prints_the_raw_token_once
    client = FakeAPIClient.new(
      "id" => "acr_1",
      "name" => "operator",
      "scopes" => ["admin"],
      "token" => "valpo_secret"
    )

    status, stdout, stderr = run_cli(client, %w[auth token create operator])

    assert_equal 0, status
    assert_includes stdout, "valpo_secret"
    assert_includes stdout, "will not be shown again"
    assert_empty stderr
    assert_equal({"name" => "operator"}, client.requests.first.fetch(:payload))
  end

  def test_api_token_create_accepts_an_explicit_admin_scope
    client = FakeAPIClient.new(
      "id" => "acr_1",
      "name" => "operator",
      "scopes" => ["admin"],
      "token" => "valpo_secret"
    )

    status, stdout, stderr = run_cli(
      client,
      ["auth", "token", "create", "operator", "--scope=admin", "--json"]
    )

    assert_equal 0, status
    assert_equal "acr_1", JSON.parse(stdout).fetch("id")
    assert_empty stderr
    assert_equal(
      {"name" => "operator", "scopes" => ["admin"]},
      client.requests.first.fetch(:payload)
    )
  end

  def test_api_token_recovery_requires_explicit_confirmation
    recovery = FakeAPICredentialRecovery.new

    status, stdout, stderr = run_cli(
      FakeAPIClient.new([]),
      %w[auth token recover rescue-admin],
      api_credential_recovery_factory: ->(config_path:) { recovery }
    )

    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "--confirm-offline-recovery"
    assert_empty recovery.names
  end

  def test_api_token_recovery_uses_the_local_database_and_prints_the_token_once
    recovery = FakeAPICredentialRecovery.new
    config_paths = []
    factory = lambda do |config_path:|
      config_paths << config_path
      recovery
    end

    status, stdout, stderr = run_cli(
      FakeAPIClient.new([]),
      %w[auth token recover rescue-admin --config=/etc/valpo/recovery.yml --confirm-offline-recovery --json],
      api_credential_recovery_factory: factory
    )

    assert_equal 0, status
    assert_empty stderr
    assert_equal ["/etc/valpo/recovery.yml"], config_paths
    assert_equal ["rescue-admin"], recovery.names
    assert_equal(
      {
        "id" => "acr_recovery",
        "name" => "rescue-admin",
        "scopes" => ["admin"],
        "token" => "valpo_recovery_secret"
      },
      JSON.parse(stdout)
    )
  end

  def test_wait_timeout_exits_one
    client = FakeAPIClient.new([
      [],
      {"id" => job_id, "status" => "running"}
    ])
    times = [0, 2]
    status, stdout, stderr = run_cli(client, ["job", "wait", job_id, "--timeout", "1"], clock: -> { times.shift || 2 })

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "Timed out"
  end

  def test_human_list_output_is_a_table
    client = FakeAPIClient.new([[
      {"name" => "acme", "service_count" => 2, "source_count" => 1, "updated_at" => "2026-07-13T12:00:00Z"}
    ]])
    status, stdout, stderr = run_cli(client, %w[project list])

    assert_equal 0, status
    assert_match(/^NAME\s+SERVICES\s+SOURCES\s+UPDATED/, stdout)
    assert_includes stdout, "acme"
    assert_empty stderr
  end

  def test_human_service_show_includes_source_build_and_resolved_port
    service = {
      "id" => service_id,
      "project" => "acme",
      "name" => "web",
      "type" => "web",
      "status" => "running",
      "app" => {
        "command" => [],
        "internal_port" => nil,
        "healthcheck_path" => nil,
        "port_mode" => "automatic",
        "resolved_internal_port" => 3000,
        "source" => {"provider" => "github", "repository" => "acme/backend", "ref" => "HEAD", "status" => "connected"},
        "build" => {"strategy" => "dockerfile", "dockerfile" => "Dockerfile", "context" => "."}
      },
      "dependencies" => [],
      "created_at" => "2026-07-14T00:00:00Z"
    }

    status, stdout, stderr = run_cli(FakeAPIClient.new([{"id" => service_id}, service]), %w[service show web --project acme])

    assert_equal 0, status
    assert_includes stdout, "github:acme/backend"
    assert_includes stdout, "HEAD"
    assert_match(/build strategy\s+dockerfile/, stdout)
    assert_includes stdout, "Dockerfile"
    assert_match(/port policy\s+automatic/, stdout)
    assert_match(/active port\s+3000/, stdout)
    assert_empty stderr
  end

  def test_optional_project_filter_is_not_treated_as_an_extra_argument
    client = FakeAPIClient.new([[]])
    status, stdout, stderr = run_cli(client, %w[service list --project acme --json])

    assert_equal 0, status
    assert_equal [], JSON.parse(stdout)
    assert_empty stderr
    assert_equal({"project" => "acme"}, client.requests.first.fetch(:query))
  end

  def test_failed_job_and_api_failure_exit_one
    client = FakeAPIClient.new([
      [],
      {"id" => job_id, "status" => "queued"},
      [],
      {"id" => job_id, "status" => "failed", "error" => "image pull failed"},
      []
    ])
    status, stdout, stderr = run_cli(client, ["job", "wait", job_id, "--json"])
    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "image pull failed"

    status, stdout, stderr = run_cli(FakeAPIClient.new(Valpo::API::Client::Error.new("connection refused")), %w[project list])
    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "connection refused"
  end

  def test_delete_requires_force_before_api_call
    client = FakeAPIClient.new([])
    status, stdout, stderr = run_cli(client, %w[service delete web --project acme])
    assert_equal 2, status
    assert_empty stdout
    assert_includes stderr, "--force is required"
    assert_empty client.requests
  end

  def test_project_apply_sends_manifest_and_renders_dry_run
    path = File.join(VALPO_TEST_DIR, "valpo.toml")
    File.write(path, "schema = 1\n[project]\nname = \"acme\"\n")
    client = FakeAPIClient.new("actions" => [])
    status, stdout, stderr = run_cli(client, ["project", "apply", path, "--dry-run", "--json"])

    assert_equal 0, status
    assert_equal({"actions" => []}, JSON.parse(stdout))
    assert_empty stderr
    request = client.requests.first
    assert_equal "/v1/projects/apply", request.fetch(:path)
    assert_equal true, request.fetch(:payload).fetch("dry_run")
  end

  def test_cli_module_loads_without_booting_database
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "-e",
      "require 'stringio'; require 'valpo'; puts Valpo::Services::Registry.names.join(','); puts Valpo::CLI.call(['--help'], out: StringIO.new, err: StringIO.new)",
      chdir: Valpo.root
    )
    assert status.success?, stderr
    assert_equal "web,worker,postgres,redis\n0\n", stdout
  end

  private

  def service_id
    "svc_01900000000070008000000000000000"
  end

  def job_id
    "job_01900000000070008000000000000000"
  end

  def event_id
    "evt_01900000000070008000000000000000"
  end

  def run_cli(
    client,
    arguments,
    clock: -> { 0 },
    input: StringIO.new,
    github_validator: FakeGitHubValidator.new,
    api_credential_recovery_factory: nil
  )
    stdout = StringIO.new
    stderr = StringIO.new
    factory = lambda do |api_url:, json:, out:, err:|
      presenter = Valpo::CLI::Presenter.new(out:, err:, json:)
      waiter = Valpo::CLI::JobWaiter.new(client:, err:, clock:, sleeper: ->(_duration) {})
      Valpo::CLI::Context.new(client:, presenter:, waiter:)
    end
    status = Valpo::CLI.call(
      arguments,
      out: stdout,
      err: stderr,
      input:,
      context_factory: factory,
      github_validator:,
      api_credential_recovery_factory:
    )
    [status, stdout.string, stderr.string]
  end

  class FakeAPIClient
    attr_reader :requests

    def initialize(responses)
      @responses = responses.is_a?(Array) ? responses.dup : [responses]
      @requests = []
    end

    def request(method, path, payload = nil, query: nil)
      requests << {method:, path:, payload:, query:}
      response = (@responses.length > 1) ? @responses.shift : @responses.first
      raise response if response.is_a?(StandardError)

      response
    end
  end

  class FakeGitHubValidator
    attr_reader :tokens

    def initialize(error: nil)
      @error = error
      @tokens = []
    end

    def validate(token)
      tokens << token
      raise @error if @error

      "octocat"
    end
  end

  class FakeAPICredentialRecovery
    Credential = Data.define(:id, :name, :scopes)

    attr_reader :names

    def initialize
      @names = []
    end

    def call(name:)
      names << name
      [Credential.new(id: "acr_recovery", name:, scopes: ["admin"]), "valpo_recovery_secret"]
    end
  end
end
