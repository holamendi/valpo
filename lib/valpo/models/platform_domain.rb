# frozen_string_literal: true

require "sequel/model"
require "securerandom"
require "time"

module Valpo
  class PlatformDomain < Sequel::Model(:platform_domains)
    STATUSES = %w[pending verified failed].freeze

    one_to_many :domains

    def before_validation
      self.hostname = Valpo::Hostname.normalize(hostname) if hostname
      self.status ||= "pending"
      self.active = false if active.nil?
      self.verification_token ||= SecureRandom.hex(24)
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:platform_domain)
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
      errors.add(:hostname, "is required") if hostname.nil? || hostname.empty?
      errors.add(:hostname, "must be a valid hostname") if hostname && !Valpo::Hostname.valid?(hostname)
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
    end

    def verification_hostname
      "valpo-#{verification_token[0, 24]}.#{hostname}"
    end

    def verified?
      status == "verified"
    end
  end
end
