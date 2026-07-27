# frozen_string_literal: true

require "json"
require "openssl"

module Valpo
  module GitHub
    class Credentials
      PUBLIC_FIELDS = %w[app_id app_domain client_id owner slug].freeze
      SECRET_FIELDS = %w[pem webhook_secret].freeze
      REQUIRED_FIELDS = (PUBLIC_FIELDS + SECRET_FIELDS).freeze
      SLUG_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,98}[a-z0-9])?\z/

      def configured?
        !record.nil?
      end

      def read
        credential = record
        return nil unless credential

        validate(credential.public_metadata.merge(credential.payload))
      end

      def write(values)
        credentials = validate(values.transform_keys(&:to_s))
        credential = record || Valpo::ProviderCredential.new(provider: "github", kind: "app")
        credential.public_metadata = credentials.slice(*PUBLIC_FIELDS)
        credential.payload = credentials.slice(*SECRET_FIELDS)
        credential.save
        credentials
      end

      def delete
        credential = record
        return false unless credential

        credential.destroy
        true
      end

      def public_values
        record&.public_metadata
      end

      private

      def record
        Valpo::ProviderCredential.where(provider: "github", kind: "app").first
      end

      def validate(values)
        missing = REQUIRED_FIELDS.reject { values[it].is_a?(String) && !values[it].empty? }
        unless missing.empty?
          raise Valpo::ValidationError, "GitHub App credentials are missing: #{missing.join(", ")}"
        end

        app_id = Integer(values.fetch("app_id"), 10)
        key = OpenSSL::PKey::RSA.new(values.fetch("pem"))
        raise ArgumentError unless app_id.positive? && key.private?
        raise ArgumentError unless Valpo::Hostname.valid?(values.fetch("app_domain"))
        raise ArgumentError unless values.fetch("slug").match?(SLUG_PATTERN)

        values.slice(*REQUIRED_FIELDS)
      rescue ArgumentError, OpenSSL::PKey::PKeyError
        raise Valpo::ValidationError, "GitHub App credentials are invalid"
      end
    end
  end
end
