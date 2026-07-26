# frozen_string_literal: true

require "openssl"
require "test_helper"

class ValpoGitHubCredentialsTest < Minitest::Test
  def test_writes_validated_credentials_to_a_private_json_file
    path = File.join(VALPO_TEST_DIR, "github-credentials", "app.json")
    store = Valpo::GitHub::Credentials.new(path)
    values = credentials

    store.write(values)

    assert_equal values, store.read
    assert_equal values.slice(*Valpo::GitHub::Credentials::PUBLIC_FIELDS), store.public_values
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_rejects_incomplete_or_invalid_credentials
    store = Valpo::GitHub::Credentials.new(File.join(VALPO_TEST_DIR, "github-invalid.json"))

    error = assert_raises Valpo::ValidationError do
      store.write(credentials.merge("pem" => "not a private key"))
    end

    assert_match "invalid", error.message
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
