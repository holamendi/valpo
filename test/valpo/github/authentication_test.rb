# frozen_string_literal: true

require "test_helper"

class ValpoGitHubAuthenticationTest < Minitest::Test
  include ValpoTestDatabase

  def test_uses_repository_scoped_app_tokens_when_the_app_is_configured
    credentials = Valpo::GitHub::Credentials.new
    credentials.define_singleton_method(:configured?) { true }
    client = FakeClient.new
    authentication = Valpo::GitHub::Authentication.new(credentials:, client:)

    assert_equal "app-token", authentication.token_for("acme/backend")
    assert_equal "acme/backend", client.repository
  end

  def test_falls_back_to_the_temporary_pat
    pat = Object.new
    pat.define_singleton_method(:read) { "pat-token" }

    authentication = Valpo::GitHub::Authentication.new(
      credentials: FakeUnconfiguredCredentials.new,
      personal_access_token: pat,
      client: FakeClient.new
    )

    assert_equal "pat-token", authentication.token_for("acme/backend")
  end

  class FakeClient
    attr_reader :repository

    def installation_token(repository)
      @repository = repository
      "app-token"
    end
  end

  class FakeUnconfiguredCredentials
    def configured?
      false
    end
  end
end
