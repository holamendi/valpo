# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class ServiceEnvironmentVariable < Sequel::Model(:service_environment_variables)
    NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    MAX_NAME_BYTES = 128
    MAX_VALUE_BYTES = 65_536

    many_to_one :service

    def value
      Valpo.secrets.decrypt(value_ciphertext, aad: value_aad)
    end

    def value=(value)
      self.id ||= Valpo::Identifier.generate(:environment_variable)
      plaintext = value.to_s
      if plaintext.bytesize > MAX_VALUE_BYTES
        raise Valpo::ValidationError, "Environment variable value must be at most #{MAX_VALUE_BYTES} bytes"
      end
      if plaintext.include?("\0") || plaintext.include?("\n") || plaintext.include?("\r")
        raise Valpo::ValidationError, "Environment variable value must not contain NUL or newlines"
      end

      self.value_ciphertext = Valpo.secrets.encrypt(plaintext, aad: value_aad)
    end

    def before_validation
      self.id ||= Valpo::Identifier.generate(:environment_variable)
      self.sensitive = true if sensitive.nil?
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
      errors.add(:service_id, "is required") if service_id.nil? || service_id.to_s.empty?
      service = Valpo::Service[service_id] if service_id
      errors.add(:service_id, "must reference an app service") if service && !service.app?
      errors.add(:name, "is required") if name.nil? || name.empty?
      if name && (name.bytesize > MAX_NAME_BYTES || !name.match?(NAME_PATTERN))
        errors.add(:name, "must be a valid environment variable name of at most #{MAX_NAME_BYTES} bytes")
      end
      errors.add(:value_ciphertext, "is required") if value_ciphertext.nil? || value_ciphertext.empty?
    end

    private

    def value_aad
      "service_environment_variable:#{id}:value"
    end
  end
end
