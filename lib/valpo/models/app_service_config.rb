# frozen_string_literal: true

require "json"
require "sequel/model"
require "valpo/models/service"

module Valpo
  class AppServiceConfig < Sequel::Model(:app_service_configs)
    unrestrict_primary_key

    many_to_one :service
    many_to_one :build_target

    def command
      JSON.parse(command_json || "[]")
    end

    def command=(value)
      self.command_json = JSON.generate(Array(value))
    end

    def validate
      super
      errors.add(:service_id, "is required") if service_id.nil? || service_id.to_s.empty?
      service = Valpo::Service[service_id] if service_id
      errors.add(:service_id, "must reference an app service") if service && !service.app?
      errors.add(:internal_port, "must be greater than 0") if internal_port && internal_port <= 0
      errors.add(:healthcheck_path, "must start with /") if healthcheck_path && !healthcheck_path.start_with?("/")
    end
  end
end
