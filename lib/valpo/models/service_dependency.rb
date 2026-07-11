# frozen_string_literal: true

require "json"
require "sequel/model"
require "time"
require "valpo/identifier"
require "valpo/models/service"

module Valpo
  class ServiceDependency < Sequel::Model(:service_dependencies)
    STATUSES = %w[binding active deleting failed].freeze

    many_to_one :service
    many_to_one :dependency_service, class: "Valpo::Service", key: :dependency_service_id

    def env
      JSON.parse(env_json || "{}")
    end

    def env=(value)
      self.env_json = JSON.generate(value || {})
    end

    def before_validation
      self.status ||= "binding"
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:dependency)
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
      errors.add(:dependency_service_id, "is required") if dependency_service_id.nil? || dependency_service_id.to_s.empty?
      errors.add(:dependency_service_id, "cannot reference itself") if service_id && service_id == dependency_service_id
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
      app = Valpo::Service[service_id] if service_id
      dependency = Valpo::Service[dependency_service_id] if dependency_service_id
      errors.add(:service_id, "must reference an app service") if app && !app.app?
      errors.add(:dependency_service_id, "must reference a managed service") if dependency && !dependency.managed?
      if app && dependency && app.project_id != dependency.project_id
        errors.add(:dependency_service_id, "must belong to the same project")
      end
    end
  end
end
