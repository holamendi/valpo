# frozen_string_literal: true

require "sequel/model"
require "time"
require "valpo/identifier"
require "valpo/models/service"

module Valpo
  class Domain < Sequel::Model(:domains)
    HOSTNAME_PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

    many_to_one :service

    def before_validation
      self.hostname = hostname.downcase if hostname
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:domain)
      self.tls_status ||= "unknown"
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
      errors.add(:hostname, "must be a valid lowercase hostname") if hostname && !hostname.match?(HOSTNAME_PATTERN)
    end
  end
end
