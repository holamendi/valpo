# frozen_string_literal: true

require "json"
require "test_helper"
require "valpo/api/client"

class ValpoAPIClientTest < Minitest::Test
  def test_request_uses_api_token_from_config
    config_path = File.join(VALPO_TEST_DIR, "api-client-token.yml")
    File.write(config_path, <<~YAML)
      api_token: config-secret
    YAML
    http = ValpoTestSupport::FakeHTTP.new(response: ValpoTestSupport::FakeHTTPResponse.new("200", JSON.generate([])))

    with_http(http) do
      Valpo::API::Client.new(base_url: "http://valpo.test", config_path: config_path).request(:get, "/projects")
    end

    assert_equal "Bearer config-secret", http.last_request["Authorization"]
  end

  def test_explicit_api_token_overrides_config
    config_path = File.join(VALPO_TEST_DIR, "api-client-explicit-token.yml")
    File.write(config_path, <<~YAML)
      api_token: config-secret
    YAML
    http = ValpoTestSupport::FakeHTTP.new(response: ValpoTestSupport::FakeHTTPResponse.new("200", JSON.generate([])))

    with_http(http) do
      Valpo::API::Client.new(
        base_url: "http://valpo.test",
        api_token: "explicit-secret",
        config_path: config_path
      ).request(:get, "/projects")
    end

    assert_equal "Bearer explicit-secret", http.last_request["Authorization"]
  end

  def test_invalid_success_json_is_reported
    http = ValpoTestSupport::FakeHTTP.new(response: ValpoTestSupport::FakeHTTPResponse.new("200", "not-json"))

    error = assert_raises(Valpo::API::Client::Error) do
      with_http(http) do
        Valpo::API::Client.new(base_url: "http://valpo.test").request(:get, "/projects")
      end
    end

    assert_match "API returned invalid JSON", error.message
  end

  def test_non_json_error_response_uses_status_and_body
    http = ValpoTestSupport::FakeHTTP.new(response: ValpoTestSupport::FakeHTTPResponse.new("503", "service unavailable"))

    error = assert_raises(Valpo::API::Client::Error) do
      with_http(http) do
        Valpo::API::Client.new(base_url: "http://valpo.test").request(:get, "/projects")
      end
    end

    assert_equal "503: service unavailable", error.message
  end

  def test_network_failure_is_reported
    http = ValpoTestSupport::FakeHTTP.new(error: Errno::ECONNREFUSED.new)

    error = assert_raises(Valpo::API::Client::Error) do
      with_http(http) do
        Valpo::API::Client.new(base_url: "http://valpo.test").request(:get, "/projects")
      end
    end

    assert_match "API request failed", error.message
  end

  private

  def with_http(http)
    Net::HTTP.stub(:new, ->(_host, _port) { http }) do
      yield
    end
  end
end
