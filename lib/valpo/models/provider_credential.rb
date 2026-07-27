# frozen_string_literal: true

require "json"
require "sequel/model"
require "time"

module Valpo
  class ProviderCredential < Sequel::Model(:provider_credentials)
    PROVIDERS = %w[github].freeze
    KINDS = %w[app pat].freeze

    def payload
      JSON.parse(Valpo.secrets.decrypt(encrypted_payload, aad: payload_aad))
    end

    def payload=(value)
      self.id ||= Valpo::Identifier.generate(:provider_credential)
      self.encrypted_payload = Valpo.secrets.encrypt(JSON.generate(value || {}), aad: payload_aad)
    end

    def public_metadata
      JSON.parse(public_metadata_json || "{}")
    end

    def public_metadata=(value)
      self.public_metadata_json = JSON.generate(value || {})
    end

    def before_validation
      self.id ||= Valpo::Identifier.generate(:provider_credential)
      self.public_metadata_json ||= "{}"
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.created_at ||= timestamp
      self.updated_at ||= timestamp
      super
    end

    def before_update
      self.updated_at = Time.now.utc
      super
    end

    def validate
      super
      errors.add(:provider, "must be one of: #{PROVIDERS.join(", ")}") unless PROVIDERS.include?(provider)
      errors.add(:kind, "must be one of: #{KINDS.join(", ")}") unless KINDS.include?(kind)
      errors.add(:encrypted_payload, "is required") if encrypted_payload.nil? || encrypted_payload.empty?
      errors.add(:public_metadata_json, "must be a JSON object") unless public_metadata.is_a?(Hash)
    rescue JSON::ParserError
      errors.add(:public_metadata_json, "must be a JSON object")
    end

    private

    def payload_aad
      "provider_credential:#{id}:payload"
    end
  end
end
