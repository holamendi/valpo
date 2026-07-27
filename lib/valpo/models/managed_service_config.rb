# frozen_string_literal: true

require "json"
require "sequel/model"

module Valpo
  class ManagedServiceConfig < Sequel::Model(:managed_service_configs)
    unrestrict_primary_key

    many_to_one :service

    def credentials
      JSON.parse(Valpo.secrets.decrypt(credentials_ciphertext, aad: credentials_aad))
    end

    def credentials=(value)
      raise Valpo::ValidationError, "service_id is required before credentials" if service_id.nil?

      self.credentials_ciphertext = Valpo.secrets.encrypt(JSON.generate(value || {}), aad: credentials_aad)
    end

    def validate
      super
      errors.add(:service_id, "is required") if service_id.nil? || service_id.to_s.empty?
      service = Valpo::Service[service_id] if service_id
      errors.add(:service_id, "must reference a managed service") if service && !service.managed?
      errors.add(:version, "is required") if version.nil? || version.to_s.strip.empty?
      errors.add(:version, "is immutable") if !new? && changed_columns.include?(:version)
      errors.add(:image, "is required") if image.nil? || image.to_s.strip.empty?
      errors.add(:credentials_ciphertext, "is required") if credentials_ciphertext.nil? || credentials_ciphertext.empty?
      errors.add(:internal_port, "must be greater than 0") if internal_port && internal_port <= 0
    end

    private

    def credentials_aad
      "managed_service_config:#{service_id}:credentials"
    end
  end
end
