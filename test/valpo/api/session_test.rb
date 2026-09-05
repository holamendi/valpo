# frozen_string_literal: true

require "json"
require "rack/test"
require "test_helper"

class ValpoAPISessionTest < Minitest::Test
  include Rack::Test::Methods
  include ValpoTestDatabase

  def app
    Valpo::API::App
  end

  def test_every_scope_can_inspect_and_revoke_only_its_own_credential
    Valpo::APICredential.issue(name: "owner")
    %w[read write admin].each do
      credential, token = Valpo::APICredential.issue(name: it, scopes: [it])
      header "Authorization", "Bearer #{token}"
      get "/v1/session"
      assert_equal 200, last_response.status
      result = JSON.parse(last_response.body)
      assert_equal credential.id, result.fetch("id")
      assert_equal [it], result.fetch("scopes")
      refute_includes last_response.body, token
      refute_includes last_response.body, "token_digest"
      unless it == "admin"
        get "/v1/api-credentials"
        assert_equal 403, last_response.status
      end
      delete "/v1/session"
      assert_equal 200, last_response.status
      assert credential.refresh.revoked_at
      get "/v1/session"
      assert_equal 401, last_response.status
    end
  end

  def test_final_admin_cannot_revoke_itself
    credential, token = Valpo::APICredential.issue(name: "owner")
    header "Authorization", "Bearer #{token}"
    delete "/v1/session"
    assert_equal 409, last_response.status
    assert_nil credential.refresh.revoked_at
  end

  def test_session_requires_a_valid_token_even_before_bootstrap
    header "Authorization", nil
    get "/v1/session"
    assert_equal 401, last_response.status
    delete "/v1/session"
    assert_equal 401, last_response.status
    _credential, token = Valpo::APICredential.issue(name: "expired", expires_at: Time.now.utc - 1)
    header "Authorization", "Bearer #{token}"
    get "/v1/session"
    assert_equal 401, last_response.status
  end

  def test_scope_exception_does_not_extend_to_other_operations_or_paths
    _credential, token = Valpo::APICredential.issue(name: "reader", scopes: ["read"])
    header "Authorization", "Bearer #{token}"
    post "/v1/session", "{}", "CONTENT_TYPE" => "application/json"
    assert_equal 403, last_response.status
    delete "/v1/session/anything"
    assert_equal 403, last_response.status
    get "/v1/session?unexpected=true"
    assert_equal 400, last_response.status
  end
end
