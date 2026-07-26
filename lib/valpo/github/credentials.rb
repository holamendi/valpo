# frozen_string_literal: true

require "json"
require "openssl"

module Valpo
  module GitHub
    class Credentials
      PUBLIC_FIELDS = %w[app_id app_domain client_id owner slug].freeze
      REQUIRED_FIELDS = (PUBLIC_FIELDS + %w[pem webhook_secret]).freeze
      SLUG_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,98}[a-z0-9])?\z/

      def initialize(path)
        @store = Valpo::Credentials::PrivateFileStore.new(path)
      end

      def configured?
        !read.nil?
      end

      def read
        serialized = store.read
        return nil unless serialized

        validate(JSON.parse(serialized))
      rescue JSON::ParserError
        raise Valpo::ValidationError, "GitHub App credentials are invalid"
      end

      def write(values)
        credentials = validate(values.transform_keys(&:to_s))
        store.write(JSON.generate(credentials))
        credentials
      end

      def delete
        store.delete
      end

      def public_values
        credentials = read
        return nil unless credentials

        credentials.slice(*PUBLIC_FIELDS)
      end

      private

      attr_reader :store

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
