# frozen_string_literal: true

require "json"
require "test_helper"

class ValpoSecretsCipherTest < Minitest::Test
  def test_encrypts_with_authenticated_context_and_supports_rotation
    path = File.join(VALPO_TEST_DIR, "cipher-test", "master.key")
    keyring = Valpo::Secrets::Keyring.new(path)
    cipher = Valpo::Secrets::Cipher.new(keyring:)
    encrypted = cipher.encrypt("top-secret", aad: "record:one")

    refute_includes encrypted, "top-secret"
    assert_equal "top-secret", cipher.decrypt(encrypted, aad: "record:one")
    assert_raises(Valpo::ValidationError) { cipher.decrypt(encrypted, aad: "record:two") }

    keyring.rotate!
    rotated = cipher.encrypt("next-secret", aad: "record:two")
    assert_equal "top-secret", cipher.decrypt(encrypted, aad: "record:one")
    assert_equal "next-secret", cipher.decrypt(rotated, aad: "record:two")
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_rejects_tampered_ciphertext_and_public_key_permissions
    path = File.join(VALPO_TEST_DIR, "cipher-tamper", "master.key")
    keyring = Valpo::Secrets::Keyring.new(path)
    cipher = Valpo::Secrets::Cipher.new(keyring:)
    values = JSON.parse(cipher.encrypt("secret", aad: "record"))
    values["c"][0] = (values.fetch("c")[0] == "0") ? "1" : "0"

    assert_raises(Valpo::ValidationError) do
      cipher.decrypt(JSON.generate(values), aad: "record")
    end

    File.chmod(0o644, path)
    error = assert_raises(Valpo::ValidationError) do
      Valpo::Secrets::Keyring.new(path).active_version
    end
    assert_match "permissions", error.message
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end
end
