# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class Service < Sequel::Model(:services)
    include Valpo::LifecycleTransitions

    NAME_PATTERN = Valpo::Project::NAME_PATTERN
    APP_KINDS = Valpo::Services::Registry.app_types
    MANAGED_KINDS = Valpo::Services::Registry.managed_types
    KINDS = (APP_KINDS + MANAGED_KINDS).freeze
    STATUSES = %w[created provisioning ready running stopped restarting deleting failed].freeze
    TRANSITIONS = {
      "created" => %w[provisioning ready running stopped deleting failed],
      "provisioning" => %w[ready running stopped deleting failed],
      "ready" => %w[provisioning running restarting stopped deleting failed],
      "running" => %w[provisioning ready restarting stopped deleting failed],
      "stopped" => %w[provisioning restarting deleting failed],
      "restarting" => %w[ready running stopped deleting failed],
      "deleting" => %w[created provisioning ready running stopped failed],
      "failed" => %w[provisioning ready running restarting stopped deleting]
    }.freeze

    many_to_one :project
    one_to_one :app_config, class: "Valpo::AppServiceConfig", key: :service_id
    one_to_one :managed_config, class: "Valpo::ManagedServiceConfig", key: :service_id
    one_to_many :dependencies, class: "Valpo::ServiceDependency", key: :service_id
    one_to_many :dependents, class: "Valpo::ServiceDependency", key: :dependency_service_id
    one_to_many :releases
    one_to_many :environment_variables, class: "Valpo::ServiceEnvironmentVariable", key: :service_id
    one_to_many :domains
    one_to_one :owned_source, class: "Valpo::Source", key: :owner_service_id
    one_to_one :owned_build_target, class: "Valpo::BuildTarget", key: :owner_service_id

    def app?
      APP_KINDS.include?(kind)
    end

    def managed?
      MANAGED_KINDS.include?(kind)
    end

    def web?
      kind == "web"
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:service)
      self.status ||= "created"
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
      errors.add(:project_id, "is required") if project_id.nil? || project_id.to_s.empty?
      errors.add(:name, "is required") if name.nil? || name.strip.empty?
      errors.add(:name, "must be a DNS-safe label of up to 63 lowercase letters, numbers, and dashes") if name && !name.match?(NAME_PATTERN)
      errors.add(:kind, "must be one of: #{KINDS.join(", ")}") unless KINDS.include?(kind)
      errors.add(:kind, "is immutable") if !new? && changed_columns.include?(:kind)
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
    end
  end
end
