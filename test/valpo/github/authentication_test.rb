# frozen_string_literal: true

require "test_helper"

class ValpoGitHubAuthenticationTest < Minitest::Test
  def test_uses_repository_scoped_app_tokens_when_the_app_is_configured
    config = Struct.new(:github_app_credentials_path, :github_token).new(
      File.join(VALPO_TEST_DIR, "configured-github-app.json"),
      "pat-token"
    )
    credentials = Valpo::GitHub::Credentials.new(config.github_app_credentials_path)
    credentials.define_singleton_method(:configured?) { true }
    client = FakeClient.new
    authentication = Valpo::GitHub::Authentication.new(config:, credentials:, client:)

    assert_equal "app-token", authentication.token_for("acme/backend")
    assert_equal "acme/backend", client.repository
  end

  def test_falls_back_to_the_temporary_pat
    config = Struct.new(:github_app_credentials_path, :github_token).new(
      File.join(VALPO_TEST_DIR, "missing-github-app.json"),
      "pat-token"
    )

    authentication = Valpo::GitHub::Authentication.new(config:, client: FakeClient.new)

    assert_equal "pat-token", authentication.token_for("acme/backend")
  end

  class FakeClient
    attr_reader :repository

    def installation_token(repository)
      @repository = repository
      "app-token"
    end
  end
end
