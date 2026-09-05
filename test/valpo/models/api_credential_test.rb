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

  def test_bootstrap_is_one_way
    credential, = Valpo::APICredential.bootstrap(name: "operator")

    assert credential.admin?
    assert Valpo::ControlPlaneState.api_bootstrapped?
    error = assert_raises(Valpo::ConflictError) { Valpo::APICredential.bootstrap(name: "second") }
    assert_equal "API bootstrap has already completed", error.message
  end

  def test_bootstrap_requires_an_admin_credential
    error = assert_raises(Valpo::ValidationError) do
      Valpo::APICredential.bootstrap(name: "reader", scopes: ["read"])
    end

    assert_equal "Bootstrap credential must include the admin scope", error.message
    refute Valpo::ControlPlaneState.api_bootstrapped?
    assert_empty Valpo::APICredential.all
  end

  def test_revoke_refuses_the_final_active_admin
    credential, = Valpo::APICredential.issue(name: "operator")

    error = assert_raises(Valpo::ConflictError) { credential.revoke! }

    assert_equal "Cannot revoke the final active admin API credential", error.message
    assert credential.refresh.active?
  end

  def test_recovery_requires_the_active_admin_set_to_be_empty
    credential, = Valpo::APICredential.issue(name: "operator")
    error = assert_raises(Valpo::ConflictError) { Valpo::APICredential.recover(name: "recovery") }
    assert_equal "An active admin API credential already exists", error.message

    credential.update(expires_at: Time.now.utc - 1)
    recovered, token = Valpo::APICredential.recover(name: "recovery")

    assert recovered.admin?
    assert_equal recovered.id, Valpo::APICredential.authenticate(token).id
    assert Valpo::ControlPlaneState.api_bootstrapped?
  end
end
