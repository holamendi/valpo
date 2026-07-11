# frozen_string_literal: true

require "open3"
require "rbconfig"
require "test_helper"
require "valpo/cli"

class ValpoCLITest < Minitest::Test
  def test_cli_exits_nonzero_and_loads_without_database
    assert_equal true, Valpo::CLI.exit_on_failure?
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", "require 'valpo/cli'; puts 'ok'")
    assert status.success?, stderr
    assert_equal "ok\n", stdout
  end

  def test_project_service_reference_resolves_to_service_id
    client = FakeAPIClient.new([
      [{"id" => service_id, "name" => "web"}],
      {"id" => service_id, "name" => "web"}
    ])
    run_cli(client, %w[services:show acme/web])

    assert_equal "/projects/acme/services", client.requests.fetch(0).fetch(:path)
    assert_equal "/services/#{service_id}", client.requests.fetch(1).fetch(:path)
  end

  def test_typed_service_id_skips_resolution
    client = FakeAPIClient.new({"id" => service_id})
    run_cli(client, ["services:show", service_id])
    assert_equal ["/services/#{service_id}"], client.requests.map { |request| request.fetch(:path) }
  end

  def test_create_service_uses_project_collection
    client = FakeAPIClient.new("service" => {"id" => service_id}, "job" => nil)
    run_cli(client, %w[services:create acme/database --type postgres --version 17])
    request = client.requests.first
    assert_equal :post, request.fetch(:method)
    assert_equal "/projects/acme/services", request.fetch(:path)
    assert_equal "database", request.fetch(:payload).fetch("name")
    assert_equal "17", request.fetch(:payload).fetch("version")
  end

  def test_bind_resolves_app_and_managed_service
    database_id = "svc_01900000000070008000000000000001"
    client = FakeAPIClient.new([
      [{"id" => service_id, "name" => "web"}, {"id" => database_id, "name" => "database"}],
      [{"id" => service_id, "name" => "web"}, {"id" => database_id, "name" => "database"}],
      {"id" => "job_01900000000070008000000000000000", "status" => "queued"}
    ])
    run_cli(client, %w[services:bind acme/web acme/database])
    request = client.requests.last
    assert_equal "/services/#{service_id}/dependencies", request.fetch(:path)
    assert_equal database_id, request.fetch(:payload).fetch("dependency_service_id")
  end

  def test_projects_apply_sends_manifest_and_dry_run
    path = File.join(VALPO_TEST_DIR, "valpo.toml")
    File.write(path, "schema = 1\n[project]\nname = \"acme\"\n")
    client = FakeAPIClient.new("actions" => [])
    run_cli(client, ["projects:apply", path, "--dry-run"])
    request = client.requests.first
    assert_equal "/projects/apply", request.fetch(:path)
    assert_equal true, request.fetch(:payload).fetch("dry_run")
    assert_includes request.fetch(:payload).fetch("manifest"), "name = \"acme\""
  end

  def test_wait_fails_when_job_fails
    job_id = "job_01900000000070008000000000000000"
    client = FakeAPIClient.new([
      {"id" => job_id, "status" => "queued"},
      {"id" => job_id, "status" => "failed", "error" => "boom"}
    ])
    cli = Valpo::CLI.new([], {}, {})
    cli.instance_variable_set(:@api_client, client)
    error = assert_raises(Thor::Error) { cli.send(:wait_for_job, job_id, timeout: 1, interval: 0.001) }
    assert_match "boom", error.message
  end

  def test_delete_requires_force_before_api_call
    client = FakeAPIClient.new({"id" => "job"})
    error = assert_raises SystemExit do
      run_cli(client, %w[services:delete acme/web])
    end
    assert_equal 1, error.status
    assert_empty client.requests
  end

  def test_api_client_errors_become_thor_errors
    client = FakeAPIClient.new(Valpo::API::Client::Error.new("connection refused"))
    cli = Valpo::CLI.new
    cli.instance_variable_set(:@api_client, client)
    error = assert_raises(Thor::Error) { cli.send(:request, :get, "/projects") }
    assert_equal "connection refused", error.message
  end

  private

  def service_id
    "svc_01900000000070008000000000000000"
  end

  def run_cli(client, arguments)
    Valpo::API::Client.stub(:new, client) { capture_io { Valpo::CLI.start(arguments) } }
  end

  class FakeAPIClient
    attr_reader :requests

    def initialize(responses)
      @responses = responses.is_a?(Array) ? responses.dup : [responses]
      @requests = []
    end

    def request(method, path, payload = nil)
      requests << {method: method, path: path, payload: payload}
      response = (@responses.length > 1) ? @responses.shift : @responses.first
      raise response if response.is_a?(StandardError)
      response
    end
  end
end
