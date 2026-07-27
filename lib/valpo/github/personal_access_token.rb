# frozen_string_literal: true

module Valpo
  module GitHub
    class PersonalAccessToken
      def configured?
        !record.nil?
      end

      def read
        record&.payload&.fetch("token")
      end

      def write(token, account:)
        value = token.to_s
        raise Valpo::ValidationError, "GitHub PAT is required" if value.empty?

        credential = record || Valpo::ProviderCredential.new(provider: "github", kind: "pat")
        credential.public_metadata = {"account" => account.to_s}
        credential.payload = {"token" => value}
        credential.save
        value
      end

      def public_values
        record&.public_metadata
      end

      def delete
        credential = record
        return false unless credential

        credential.destroy
        true
      end

      private

      def record
        Valpo::ProviderCredential.where(provider: "github", kind: "pat").first
      end
    end
  end
end
