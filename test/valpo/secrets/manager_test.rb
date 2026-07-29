# frozen_string_literal: true

require "json"
require "test_helper"

class ValpoSecretsManagerTest < Minitest::Test
  include ValpoTestDatabase

  def setup
    super
    @original_secrets = Valpo.secrets
    @key_path = File.join(VALPO_TEST_DIR, "manager-test", name, "master.key")
    @cipher = Valpo::Secrets::Cipher.new(keyring: Valpo::Secrets::Keyring.new(@key_path))
    Valpo.secrets = @cipher
  end

  def teardown
    Valpo.secrets = @original_secrets
    super
  end

  def test_verifies_and_reencrypts_every_encrypted_record_type
    records = encrypted_records
    stale_cipher = Valpo::Secrets::Cipher.new(keyring: Valpo::Secrets::Keyring.new(@key_path))
    assert_equal 1, stale_cipher.active_key_version
    before = ciphertexts(records)

    verification = manager.verify
    rotation = manager.rotate

    assert_equal 1, verification.fetch(:active_key_version)
    assert_equal 3, verification.fetch(:total)
    assert_equal(
      {
        "managed_service_credentials" => 1,
        "service_environment_variables" => 1,
        "provider_credentials" => 1
      },
      verification.fetch(:records)
    )
    assert_equal 1, rotation.fetch(:previous_key_version)
    assert_equal 2, rotation.fetch(:active_key_version)
    assert_equal 2, stale_cipher.active_key_version

    after = ciphertexts(records, refresh: true)
    after.each_value { assert_equal 2, JSON.parse(it).fetch("k") }
    refute_equal before, after
    assert_equal "database-secret", records.fetch(:managed).refresh.credentials.fetch("password")
    assert_equal "feature-secret", records.fetch(:environment).refresh.value
    assert_equal "github-secret", records.fetch(:provider).refresh.payload.fetch("token")

    assert_equal(
      "github-secret",
      stale_cipher.decrypt(before.fetch(:provider), aad: "provider_credential:#{records.fetch(:provider).id}:payload")
        .then { JSON.parse(it).fetch("token") }
    )
    assert_equal(
      "github-secret",
      stale_cipher.decrypt(after.fetch(:provider), aad: "provider_credential:#{records.fetch(:provider).id}:payload")
        .then { JSON.parse(it).fetch("token") }
    )
  end

  def test_refuses_rotation_before_changing_the_key_when_verification_fails
    records = encrypted_records
    records.fetch(:environment).update(value_ciphertext: "not-an-envelope")
    before = ciphertexts(records, refresh: true)

    error = assert_raises(Valpo::ValidationError) { manager.rotate }

    assert_match "service_environment_variables", error.message
    assert_equal 1, @cipher.active_key_version
    assert_equal before, ciphertexts(records, refresh: true)
  end

  def test_rolls_back_every_database_change_if_reencryption_fails
    records = encrypted_records
    before = ciphertexts(records)
    failing = FailingCipher.new(@cipher, fail_on_encrypt: 2)

    error = assert_raises(Valpo::ValidationError) do
      Valpo::Secrets::Manager.new(secrets: failing).rotate
    end

    assert_equal "Injected encryption failure", error.message
    assert_equal 2, @cipher.active_key_version
    assert_equal before, ciphertexts(records, refresh: true)
    assert_equal 3, manager.verify.fetch(:total)
  end

  private

  def manager
    Valpo::Secrets::Manager.new
  end

  def encrypted_records
    managed_service = create_managed_service
    managed = Valpo::ManagedServiceConfig[managed_service.id]
    managed.credentials = {"password" => "database-secret"}
    managed.save_changes

    app = create_app_service(project: managed_service.project, name: "app")
    environment = Valpo::ServiceEnvironmentVariable.new(service_id: app.id, name: "FEATURE_SECRET")
    environment.value = "feature-secret"
    environment.save

    provider = Valpo::ProviderCredential.new(provider: "github", kind: "pat")
    provider.public_metadata = {"account" => "octocat"}
    provider.payload = {"token" => "github-secret"}
    provider.save

    {managed:, environment:, provider:}
  end

  def ciphertexts(records, refresh: false)
    records.transform_values { refresh ? it.refresh : it }.transform_values do
      case it
      when Valpo::ManagedServiceConfig then it.credentials_ciphertext
      when Valpo::ServiceEnvironmentVariable then it.value_ciphertext
      when Valpo::ProviderCredential then it.encrypted_payload
      end
    end
  end

  class FailingCipher
    def initialize(delegate, fail_on_encrypt:)
      @delegate = delegate
      @fail_on_encrypt = fail_on_encrypt
      @encryptions = 0
    end

    def active_key_version
      @delegate.active_key_version
    end

    def rotate_key!
      @delegate.rotate_key!
    end

    def decrypt(...)
      @delegate.decrypt(...)
    end

    def encrypt(...)
      @encryptions += 1
      raise Valpo::ValidationError, "Injected encryption failure" if @encryptions == @fail_on_encrypt

      @delegate.encrypt(...)
    end
  end
end
