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

  def test_create_service_documents_and_rejects_incompatible_options_locally
    client = FakeAPIClient.new([])
    status, _stdout, stderr = run_cli(client, %w[service create acme/database --type postgres --port 3000])
    assert_equal 2, status
    assert_includes stderr, "--port is not valid for postgres"

    status, _stdout, stderr = run_cli(client, %w[service create acme/web --type web --version 18])
    assert_equal 2, status
    assert_includes stderr, "--version is not valid"
    assert_empty client.requests
  end

  def test_create_service_uses_project_collection_and_no_wait_returns_queued_job
    job = {"id" => job_id, "status" => "queued"}
    client = FakeAPIClient.new("service" => {"id" => service_id}, "job" => job)
    status, stdout, stderr = run_cli(client, %w[service create acme/database --type postgres --version 17 --no-wait --json])

    assert_equal 0, status
    assert_equal job_id, JSON.parse(stdout).fetch("job").fetch("id")
    assert_empty stderr
    request = client.requests.first
    assert_equal :post, request.fetch(:method)
    assert_equal "/projects/acme/services", request.fetch(:path)
    assert_equal "database", request.fetch(:payload).fetch("name")
    assert_equal "17", request.fetch(:payload).fetch("version")
    assert_equal 1, client.requests.length
  end

  def test_service_reference_uses_exact_lookup_and_is_cached
    database_id = "svc_01900000000070008000000000000001"
    client = FakeAPIClient.new([
      {"id" => service_id, "name" => "web"},
      {"id" => database_id, "name" => "database"},
      {"id" => job_id, "status" => "queued"}
    ])
    status, = run_cli(client, %w[service bind acme/web acme/database --no-wait --json])

    assert_equal 0, status
    assert_equal [
      "/projects/acme/services/web",
      "/projects/acme/services/database",
      "/services/#{service_id}/dependencies"
    ], client.requests.map { |request| request.fetch(:path) }

    cache_client = FakeAPIClient.new("id" => service_id)
    resolver = Valpo::CLI::ReferenceResolver.new(client: cache_client)
    2.times { assert_equal service_id, resolver.service_id("acme/web") }
    assert_equal 1, cache_client.requests.count { |request| request.fetch(:path) == "/projects/acme/services/web" }
  end

  def test_typed_service_id_skips_resolution
    client = FakeAPIClient.new("id" => service_id, "reference" => "acme/web", "kind" => "web", "status" => "created", "app" => {}, "dependencies" => [])
    status, = run_cli(client, ["service", "show", service_id, "--json"])
    assert_equal 0, status
    assert_equal ["/services/#{service_id}"], client.requests.map { |request| request.fetch(:path) }
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
      [event, finished_event],
      {"id" => job_id, "status" => "succeeded", "progress" => 100},
      [event, finished_event]
    ])
    status, stdout, stderr = run_cli(client, %w[service deploy acme/web --image nginx:alpine --json])

    assert_equal 0, status
    assert_equal "succeeded", JSON.parse(stdout).fetch("status")
    assert_equal 1, stderr.scan("Deploy started").length
    assert_equal 1, stderr.scan("healthy").length
    assert_equal 3, client.requests.count { |request| request.fetch(:path).end_with?("/events") }
  end

  def test_source_deploy_sends_ref_without_requiring_an_image
    client = FakeAPIClient.new([
      {"id" => service_id},
      {"id" => job_id, "status" => "queued"}
    ])

    status, = run_cli(client, %w[service deploy acme/web --ref release --no-wait --json])

    assert_equal 0, status
    request = client.requests.last
    assert_equal({"ref" => "release"}, request.fetch(:payload))
  end

  def test_auth_login_reads_token_stdin_and_writes_a_private_file
    token_path = File.join(VALPO_TEST_DIR, "credentials", "github-token")
    config_path = File.join(VALPO_TEST_DIR, "github-token-config.yml")
    File.write(config_path, "github_token_path: #{token_path}\n")

    status, stdout, stderr = run_cli(
      FakeAPIClient.new([]),
      ["auth", "login", "github", "--with-token", "--config", config_path, "--json"],
      input: StringIO.new("github_pat_secret\n")
    )

    assert_equal 0, status
    assert_equal "github_pat_secret\n", File.read(token_path)
    assert_equal 0o600, File.stat(token_path).mode & 0o777
    assert_equal true, JSON.parse(stdout).fetch("authenticated")
    assert_equal "octocat", JSON.parse(stdout).fetch("account")
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

  def test_auth_status_and_logout_manage_the_stored_token
    token_path = File.join(VALPO_TEST_DIR, "auth-lifecycle", "github-token")
    config_path = File.join(VALPO_TEST_DIR, "auth-lifecycle.yml")
    File.write(config_path, "github_token_path: #{token_path}\n")
    Valpo::Credentials::FileStore.new(token_path).write("github_pat_secret")

    status, stdout, = run_cli(
      FakeAPIClient.new([]),
      ["auth", "status", "github", "--config", config_path, "--json"]
    )
    assert_equal 0, status
    assert_equal true, JSON.parse(stdout).fetch("authenticated")

    status, stdout, = run_cli(
      FakeAPIClient.new([]),
      ["auth", "logout", "github", "--config", config_path, "--json"]
    )
    assert_equal 0, status
    assert_equal true, JSON.parse(stdout).fetch("removed")
    refute_path_exists token_path
  end

  def test_auth_login_uses_noecho_for_an_interactive_terminal
    token_path = File.join(VALPO_TEST_DIR, "auth-tty", "github-token")
    config_path = File.join(VALPO_TEST_DIR, "auth-tty.yml")
    File.write(config_path, "github_token_path: #{token_path}\n")
    input = FakeTTY.new("github_pat_secret\n")

    status, _stdout, stderr = run_cli(
      FakeAPIClient.new([]),
      ["auth", "login", "github", "--config", config_path],
      input: input
    )

    assert_equal 0, status
    assert input.noecho_called
    assert_includes stderr, "GitHub PAT:"
    assert_includes stderr, "contents=read"
    refute_includes stderr, "github_pat_secret"
  end

  def test_auth_login_does_not_store_a_token_rejected_by_github
    token_path = File.join(VALPO_TEST_DIR, "auth-invalid", "github-token")
    config_path = File.join(VALPO_TEST_DIR, "auth-invalid.yml")
    File.write(config_path, "github_token_path: #{token_path}\n")
    validator = FakeGitHubValidator.new(error: Valpo::ValidationError.new("GitHub rejected the PAT"))

    status, stdout, stderr = run_cli(
      FakeAPIClient.new([]),
      ["auth", "login", "github", "--with-token", "--config", config_path],
      input: StringIO.new("github_pat_invalid\n"),
      github_validator: validator
    )

    assert_equal 1, status
    assert_empty stdout
    assert_includes stderr, "GitHub rejected"
    refute File.exist?(token_path)
    refute_includes stderr, "github_pat_invalid"
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

  def test_optional_project_filter_is_not_treated_as_an_extra_argument
    client = FakeAPIClient.new([[]])
    status, stdout, stderr = run_cli(client, %w[service list acme --json])

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
    status, stdout, stderr = run_cli(client, %w[service delete acme/web])
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
    assert_equal "/projects/apply", request.fetch(:path)
    assert_equal true, request.fetch(:payload).fetch("dry_run")
  end

  def test_cli_module_loads_without_booting_database
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "-e",
      "require 'stringio'; require 'valpo'; puts Valpo::Services::Definitions::TYPES.keys.join(','); puts Valpo::CLI.call(['--help'], out: StringIO.new, err: StringIO.new)",
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

  def run_cli(client, arguments, clock: -> { 0 }, input: StringIO.new, github_validator: FakeGitHubValidator.new)
    stdout = StringIO.new
    stderr = StringIO.new
    factory = lambda do |api_url:, config:, json:, out:, err:|
      presenter = Valpo::CLI::Presenter.new(out: out, err: err, json: json)
      waiter = Valpo::CLI::JobWaiter.new(client: client, err: err, clock: clock, sleeper: ->(_duration) {})
      Valpo::CLI::Context.new(client: client, presenter: presenter, waiter: waiter)
    end
    status = Valpo::CLI.call(
      arguments,
      out: stdout,
      err: stderr,
      input: input,
      context_factory: factory,
      github_validator: github_validator
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
      requests << {method: method, path: path, payload: payload, query: query}
      response = (@responses.length > 1) ? @responses.shift : @responses.first
      raise response if response.is_a?(StandardError)

      response
    end
  end

  class FakeTTY
    attr_reader :noecho_called

    def initialize(value)
      @value = value
      @noecho_called = false
    end

    def tty?
      true
    end

    def noecho
      @noecho_called = true
      yield self
    end

    def gets
      @value
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
end
