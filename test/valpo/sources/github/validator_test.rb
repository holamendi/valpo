# frozen_string_literal: true

require "test_helper"

class ValpoSourcesGitHubValidatorTest < Minitest::Test
  def test_validates_the_token_and_returns_the_authenticated_login
    requester = FakeRequester.new(status: 200, body: JSON.generate("login" => "octocat"))

    login = Valpo::Sources::GitHub::Validator.new(requester: requester).validate("github_pat_secret")

    assert_equal "octocat", login
    uri, headers = requester.request
    assert_equal "https://api.github.com/user", uri.to_s
    assert_equal "Bearer github_pat_secret", headers.fetch("Authorization")
    assert_equal "2026-03-10", headers.fetch("X-GitHub-Api-Version")
    assert_equal "application/vnd.github+json", headers.fetch("Accept")
  end

  def test_rejects_invalid_tokens_without_echoing_them
    error = assert_raises Valpo::ValidationError do
      Valpo::Sources::GitHub::Validator.new(requester: FakeRequester.new(status: 401, body: "{}")).validate("github_pat_secret")
    end

    assert_match "rejected", error.message
    refute_includes error.message, "github_pat_secret"
  end

  class FakeRequester
    attr_reader :request

    def initialize(status:, body:)
      @response = {status: status, body: body}
    end

    def get(uri, headers)
      @request = [uri, headers]
      @response
    end
  end
end
