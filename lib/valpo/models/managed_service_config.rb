# frozen_string_literal: true

require "json"
require "sequel/model"

module Valpo
  class ManagedServiceConfig < Sequel::Model(:managed_service_configs)
    unrestrict_primary_key

    many_to_one :service

    def credentials
      JSON.parse(credentials_json || "{}")
    end

    def credentials=(value)
      self.credentials_json = JSON.generate(value || {})
    end

    def validate
      super
      errors.add(:service_id, "is required") if service_id.nil? || service_id.to_s.empty?
      service = Valpo::Service[service_id] if service_id
      errors.add(:service_id, "must reference a managed service") if service && !service.managed?
      errors.add(:version, "is required") if version.nil? || version.to_s.strip.empty?
      errors.add(:version, "is immutable") if !new? && changed_columns.include?(:version)
      errors.add(:image, "is required") if image.nil? || image.to_s.strip.empty?
      errors.add(:plan, "is required") if plan.nil? || plan.to_s.strip.empty?
      errors.add(:internal_port, "must be greater than 0") if internal_port && internal_port <= 0
    end
  end
end
