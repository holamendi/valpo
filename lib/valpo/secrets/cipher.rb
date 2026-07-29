# frozen_string_literal: true

require "json"
require "openssl"

module Valpo
  module Secrets
    class Cipher
      ALGORITHM = "aes-256-gcm"
      FORMAT_VERSION = 1
      NONCE_BYTES = 12
      TAG_BYTES = 16

      def initialize(keyring:)
        @keyring = keyring
      end

      def active_key_version
        keyring.active_version
      end

      def rotate_key!
        keyring.rotate!
      end

      def encrypt(value, aad:)
        plaintext = value.to_s
        version = keyring.active_version
        cipher = OpenSSL::Cipher.new(ALGORITHM)
        cipher.encrypt
        cipher.key = keyring.key(version)
        nonce = OpenSSL::Random.random_bytes(NONCE_BYTES)
        cipher.iv = nonce
        cipher.auth_data = aad.to_s
        ciphertext = cipher.update(plaintext) + cipher.final
        JSON.generate(
          "v" => FORMAT_VERSION,
          "k" => version,
          "n" => nonce.unpack1("H*"),
          "c" => ciphertext.unpack1("H*"),
          "t" => cipher.auth_tag(TAG_BYTES).unpack1("H*")
        )
      end

      def decrypt(envelope, aad:)
        values = JSON.parse(envelope.to_s)
        raise Valpo::ValidationError, "Encrypted value has an unsupported format" unless values["v"] == FORMAT_VERSION

        cipher = OpenSSL::Cipher.new(ALGORITHM)
        cipher.decrypt
        cipher.key = keyring.key(Integer(values.fetch("k")))
        cipher.iv = decode_hex(values.fetch("n"))
        cipher.auth_tag = decode_hex(values.fetch("t"))
        cipher.auth_data = aad.to_s
        cipher.update(decode_hex(values.fetch("c"))) + cipher.final
      rescue JSON::ParserError, KeyError, ArgumentError, OpenSSL::Cipher::CipherError
        raise Valpo::ValidationError, "Encrypted value cannot be decrypted"
      end

      private

      attr_reader :keyring

      def decode_hex(value)
        raise ArgumentError unless value.is_a?(String) && value.length.even? && value.match?(/\A[0-9a-f]*\z/)

        [value].pack("H*")
      end
    end
  end
end
