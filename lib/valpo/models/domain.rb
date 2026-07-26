# frozen_string_literal: true

require "sequel/model"
require "securerandom"
require "time"

module Valpo
  class Domain < Sequel::Model(:domains)
    KINDS = %w[generated custom].freeze
    STATUSES = %w[pending verified failed].freeze

    many_to_one :service
    many_to_one :platform_domain

    def self.default_hostname(project_name:, service_name:, app_domain:)
      "#{service_name}.#{project_name}.#{app_domain}"
    end

    def before_validation
      self.hostname = hostname.downcase if hostname
      self.kind ||= "custom"
      self.status ||= "pending"
      self.verification_token ||= SecureRandom.hex(24)
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:domain)
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
      errors.add(:service_id, "must reference a web service") if service && !service.web?
      errors.add(:hostname, "is required") if hostname.nil? || hostname.strip.empty?
      errors.add(:hostname, "must be a valid lowercase hostname") if hostname && !Valpo::Hostname.valid?(hostname)
      if hostname && Valpo::Domains::Configuration.reserved_hostname?(hostname)
        errors.add(:hostname, "is reserved for the GitHub integration")
      end
      errors.add(:kind, "must be one of: #{KINDS.join(", ")}") unless KINDS.include?(kind)
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
      errors.add(:platform_domain_id, "is required for generated domains") if kind == "generated" && platform_domain_id.nil?
    end

    def verified?
      status == "verified"
    end
  end
end
