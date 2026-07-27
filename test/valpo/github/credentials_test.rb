# frozen_string_literal: true

require "openssl"
require "test_helper"

class ValpoGitHubCredentialsTest < Minitest::Test
  include ValpoTestDatabase

  def test_writes_validated_credentials_to_encrypted_database_storage
    store = Valpo::GitHub::Credentials.new
    values = credentials

    store.write(values)

    assert_equal values, store.read
    assert_equal values.slice(*Valpo::GitHub::Credentials::PUBLIC_FIELDS), store.public_values
    record = Valpo::ProviderCredential.where(provider: "github", kind: "app").first
    refute_includes record.encrypted_payload, values.fetch("webhook_secret")
    refute_includes record.encrypted_payload, "PRIVATE KEY"
  end

  def test_rejects_incomplete_or_invalid_credentials
    store = Valpo::GitHub::Credentials.new

    error = assert_raises Valpo::ValidationError do
      store.write(credentials.merge("pem" => "not a private key"))
    end

    assert_match "invalid", error.message
  end

  def test_personal_access_token_is_encrypted
    store = Valpo::GitHub::PersonalAccessToken.new
    store.write("github_pat_secret", account: "octocat")

    assert_equal "github_pat_secret", store.read
    assert_equal({"account" => "octocat"}, store.public_values)
    record = Valpo::ProviderCredential.where(provider: "github", kind: "pat").first
    refute_includes record.encrypted_payload, "github_pat_secret"
  end

  private

  def credentials
    {
      "app_id" => "123",
      "app_domain" => "apps.example.com",
      "client_id" => "Iv1.client",
      "owner" => "octocat",
      "slug" => "valpo-test",
      "pem" => OpenSSL::PKey::RSA.generate(1024).to_pem,
      "webhook_secret" => "webhook-secret"
    }
  end
end
