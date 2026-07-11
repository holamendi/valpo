# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class Release < Sequel::Model(:releases)
    STATUSES = %w[pending active inactive failed].freeze
    SOURCE_TYPES = %w[registry git].freeze

    many_to_one :service
    many_to_one :build_target

    def self.next_version(service_id)
      where(service_id: service_id).max(:version).to_i + 1
    end

    def self.active_for_service(service_id)
      where(service_id: service_id, status: "active").order(Sequel.desc(:version)).first
    end

    def self.previous_deployable_for_service(service_id, excluding_release_id: nil)
      dataset = where(service_id: service_id, status: %w[active inactive])
      dataset = dataset.exclude(id: excluding_release_id) if excluding_release_id
      dataset.order(Sequel.desc(:version)).first
    end

    def before_validation
      self.status ||= "pending"
      self.version ||= self.class.next_version(service_id) if service_id
      super
    end

    def before_create
      self.id ||= Valpo::Identifier.generate(:release)
      self.created_at ||= Time.now.utc
      super
    end

    def validate
      super
      errors.add(:service_id, "is required") if service_id.nil? || service_id.to_s.empty?
      errors.add(:version, "is required") if version.nil?
      errors.add(:source_type, "must be one of: #{SOURCE_TYPES.join(", ")}") unless SOURCE_TYPES.include?(source_type)
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
      errors.add(:internal_port, "must be greater than 0") if internal_port && internal_port <= 0
      errors.add(:healthcheck_path, "must start with /") if healthcheck_path && !healthcheck_path.start_with?("/")
    end

    def activate!(activated_at: Time.now.utc)
      db.transaction do
        self.class.where(service_id: service_id, status: "active").exclude(id: id).update(status: "inactive")
        update(status: "active", activated_at: activated_at)
      end
    end

    def fail!
      update(status: "failed")
    end
  end
end
