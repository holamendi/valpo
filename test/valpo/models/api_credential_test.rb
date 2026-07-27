# frozen_string_literal: true

require "test_helper"

class ValpoAPICredentialTest < Minitest::Test
  include ValpoTestDatabase

  def test_issues_hashes_authenticates_and_revokes_tokens
    credential, token = Valpo::APICredential.issue(name: "operator", scopes: %w[read write])

    assert_match(/\Avalpo_/, token)
    refute_equal token, credential.token_digest
    assert_equal credential.id, Valpo::APICredential.authenticate(token).id
    assert credential.allows?("GET")
    assert credential.allows?("POST")

    credential.revoke!
    assert_nil Valpo::APICredential.authenticate(token)
  end

  def test_enforces_scopes_and_expiration
    reader, reader_token = Valpo::APICredential.issue(name: "reader", scopes: ["read"])
    assert reader.allows?("GET")
    refute reader.allows?("DELETE")

    _expired, token = Valpo::APICredential.issue(
      name: "expired",
      expires_at: Time.now.utc - 1
    )
    assert_nil Valpo::APICredential.authenticate(token)
    assert_equal reader.id, Valpo::APICredential.authenticate(reader_token).id
  end
end
