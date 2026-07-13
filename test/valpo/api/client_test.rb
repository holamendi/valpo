# frozen_string_literal: true

require "json"
require "test_helper"

class ValpoAPIClientTest < Minitest::Test
  def test_request_uses_api_token_from_config_and_sets_timeouts
    config_path = File.join(VALPO_TEST_DIR, "api-client-token.yml")
    File.write(config_path, "api_token: config-secret\n")
    http = fake_http("200", JSON.generate([]))

    client(http, config_path: config_path).request(:get, "/projects")

    assert_equal "Bearer config-secret", http.last_request["Authorization"]
    assert_equal 5, http.open_timeout
    assert_equal 60, http.read_timeout
  end

  def test_environment_token_overrides_config
    config_path = File.join(VALPO_TEST_DIR, "api-client-env-token.yml")
    File.write(config_path, "api_token: config-secret\n")
    http = fake_http("200", JSON.generate([]))

    with_env("VALPO_API_TOKEN", "env-secret") do
      client(http, config_path: config_path).request(:get, "/projects")
    end

    assert_equal "Bearer env-secret", http.last_request["Authorization"]
  end

  def test_structured_query_is_encoded
    http = fake_http("200", JSON.generate([]))
    client(http).request(:get, "/services", query: {"project" => "hello world", "unused" => nil})

    assert_equal "/services?project=hello+world", http.last_request.path
  end

  def test_invalid_base_urls_are_rejected
    ["", "valpo.test", "ftp://valpo.test", "http://user:secret@valpo.test", "http://valpo.test?x=1"].each do |url|
      assert_raises(Valpo::API::Client::Error) { Valpo::API::Client.new(base_url: url) }
    end
  end

  def test_invalid_success_json_is_reported
    error = assert_raises(Valpo::API::Client::Error) { client(fake_http("200", "not-json")).request(:get, "/projects") }
    assert_match "API returned invalid JSON", error.message
  end

  def test_non_json_error_response_uses_status_and_bounded_body
    body = "x" * 5000
    error = assert_raises(Valpo::API::Client::Error) { client(fake_http("503", body)).request(:get, "/projects") }

    assert_match(/\A503: x+\.\.\.\z/, error.message)
    assert_operator error.message.bytesize, :<=, Valpo::API::Client::MAX_ERROR_BODY_BYTES + 8

    json_error = assert_raises(Valpo::API::Client::Error) do
      client(fake_http("422", JSON.generate("message" => body))).request(:get, "/projects")
    end
    assert_operator json_error.message.bytesize, :<=, Valpo::API::Client::MAX_ERROR_BODY_BYTES + 8
  end

  def test_network_failure_is_reported
    http = ValpoTestSupport::FakeHTTP.new(error: Errno::ECONNREFUSED.new)
    error = assert_raises(Valpo::API::Client::Error) { client(http).request(:get, "/projects") }
    assert_match "API request failed", error.message
  end

  private

  def client(http, config_path: nil)
    Valpo::API::Client.new(
      base_url: "http://valpo.test",
      config_path: config_path,
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
