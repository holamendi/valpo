# frozen_string_literal: true

require "json"
require "net/http"
require "test_helper"

class ValpoAPIClientTest < Minitest::Test
  def test_request_sets_timeouts_without_adding_authentication
    http = fake_http("200", JSON.generate([]))

    client(http).request(:get, "/v1/projects")

    assert_nil http.last_request["Authorization"]
    assert_equal 5, http.open_timeout
    assert_equal 60, http.read_timeout
  end

  def test_environment_token_is_used_for_authentication
    http = fake_http("200", JSON.generate([]))

    with_env("VALPO_API_TOKEN", "env-secret") do
      client(http).request(:get, "/v1/projects")
    end

    assert_equal "Bearer env-secret", http.last_request["Authorization"]
  end

  def test_structured_query_is_encoded
    http = fake_http("200", JSON.generate([]))
    client(http).request(:get, "/v1/services", query: {"project" => "hello world", "unused" => nil})

    assert_equal "/v1/services?project=hello+world", http.last_request.path
  end

  def test_explicit_token_overrides_environment_and_nil_disables_it
    with_env("VALPO_API_TOKEN", "environment-secret") do
      http = fake_http("200", "{}")
      Valpo::API::Client.new(base_url: "https://valpo.test", token: "saved-secret", http_factory: ->(_uri) { http }).request(:get, "/health")
      assert_equal "Bearer saved-secret", http.last_request["Authorization"]
      Valpo::API::Client.new(base_url: "https://valpo.test", token: nil, http_factory: ->(_uri) { http }).request(:get, "/health")
      assert_nil http.last_request["Authorization"]
    end
  end

  def test_credentials_cannot_be_forwarded_by_a_redirect_or_absolute_path
    http = fake_http("302", "{}")
    authenticated = Valpo::API::Client.new(base_url: "https://valpo.test/api", token: "saved-secret", http_factory: ->(_uri) { http })
    %w[https://other.test/ //other.test/ /../outside].each do |path|
      assert_raises(Valpo::API::Client::Error) { authenticated.request(:get, path) }
    end
    assert_nil http.last_request
    error = assert_raises(Valpo::API::Client::Error) { authenticated.request(:get, "/health") }
    assert_equal "API redirects are not followed", error.message
  end

  def test_error_bodies_do_not_echo_the_credential
    http = fake_http("401", JSON.generate("message" => "Rejected saved-secret"))
    authenticated = Valpo::API::Client.new(base_url: "https://valpo.test", token: "saved-secret", http_factory: ->(_uri) { http })
    error = assert_raises(Valpo::API::Client::Error) { authenticated.request(:get, "/health") }
    refute_includes error.message, "saved-secret"
  end

  def test_put_and_patch_are_supported
    {
      put: Net::HTTP::Put,
      patch: Net::HTTP::Patch
    }.each do |method, request_class|
      http = fake_http("200", JSON.generate({}))

      client(http).request(method, "/resource", {"name" => "example"})

      assert_instance_of request_class, http.last_request
    end
  end

  def test_invalid_base_urls_are_rejected
    ["", "valpo.test", "ftp://valpo.test", "http://user:secret@valpo.test", "http://valpo.test?x=1"].each do
      assert_raises(Valpo::API::Client::Error) { Valpo::API::Client.new(base_url: it) }
    end
  end

  def test_invalid_success_json_is_reported
    error = assert_raises(Valpo::API::Client::Error) { client(fake_http("200", "not-json")).request(:get, "/v1/projects") }
    assert_match "API returned invalid JSON", error.message
  end

  def test_non_json_error_response_uses_status_and_bounded_body
    body = "x" * 5000
    error = assert_raises(Valpo::API::Client::Error) { client(fake_http("503", body)).request(:get, "/v1/projects") }

    assert_match(/\A503: x+\.\.\.\z/, error.message)
    assert_operator error.message.bytesize, :<=, Valpo::API::Client::MAX_ERROR_BODY_BYTES + 8

    json_error = assert_raises(Valpo::API::Client::Error) do
      client(fake_http("422", JSON.generate("message" => body))).request(:get, "/v1/projects")
    end
    assert_operator json_error.message.bytesize, :<=, Valpo::API::Client::MAX_ERROR_BODY_BYTES + 8
  end

  def test_network_failure_is_reported
    http = ValpoTestSupport::FakeHTTP.new(error: Errno::ECONNREFUSED.new)
    error = assert_raises(Valpo::API::Client::Error) { client(http).request(:get, "/v1/projects") }
    assert_match "API request failed", error.message
  end

  private

  def client(http)
    Valpo::API::Client.new(
      base_url: "http://valpo.test",
      http_factory: ->(_uri) { http }
    )
  end

  def fake_http(code, body)
    ValpoTestSupport::FakeHTTP.new(response: ValpoTestSupport::FakeHTTPResponse.new(code, body))
  end

  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end
end
