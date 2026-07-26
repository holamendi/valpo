# frozen_string_literal: true

require "json"
require "openssl"
require "test_helper"

class ValpoGitHubClientTest < Minitest::Test
  def test_converts_a_manifest_without_authentication
    requester = FakeRequester.new(
      status: 201,
      body: JSON.generate(
        "id" => 123,
        "client_id" => "Iv1.client",
        "slug" => "valpo-test",
        "owner" => {"login" => "octocat"},
        "pem" => private_key,
        "webhook_secret" => "hook-secret"
      )
    )

    result = Valpo::GitHub::Client.new(credentials: FakeCredentials.new(credentials), requester:).convert_manifest("code-123")

    assert_equal "123", result.fetch("app_id")
    method, uri, headers, = requester.requests.fetch(0)
    assert_equal :post, method
    assert_equal "/app-manifests/code-123/conversions", uri.path
    refute headers.key?("Authorization")
  end

  def test_mints_a_repository_installation_token_with_an_app_jwt
    requester = FakeRequester.new(
      {status: 200, body: JSON.generate("id" => 987)},
      {status: 201, body: JSON.generate("token" => "installation-token")}
    )
    client = Valpo::GitHub::Client.new(
      credentials: FakeCredentials.new(credentials),
      requester:,
      clock: -> { 1_800_000_000 }
    )

    assert_equal "installation-token", client.installation_token("acme/backend")

    lookup, token = requester.requests
    assert_equal "/repos/acme/backend/installation", lookup.fetch(1).path
    authorization = lookup.fetch(2).fetch("Authorization")
    assert_match(/\ABearer [^.]+\.[^.]+\.[^.]+\z/, authorization)
    refute_includes authorization, "="
    assert_equal "/app/installations/987/access_tokens", token.fetch(1).path
    assert_equal({"permissions" => {"contents" => "read"}}, JSON.parse(token.fetch(3)))
  end

  private

  def private_key
    @private_key ||= OpenSSL::PKey::RSA.generate(2048).to_pem
  end

  def credentials
    {
      "app_id" => "123",
      "client_id" => "Iv1.client",
      "owner" => "octocat",
      "slug" => "valpo-test",
      "pem" => private_key,
      "webhook_secret" => "hook-secret"
    }
  end

  class FakeCredentials
    def initialize(values)
      @values = values
    end

    def read
      @values
    end
  end

  class FakeRequester
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def request(method, uri, headers:, body: nil)
      requests << [method, uri, headers, body]
      @responses.shift
    end
  end
end
