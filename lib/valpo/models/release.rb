# frozen_string_literal: true

require "securerandom"
require "sequel/model"
require "time"

module Valpo
  class Release < Sequel::Model(:releases)
    STATUSES = %w[pending active inactive failed].freeze
    SOURCE_TYPES = %w[registry].freeze

    many_to_one :project

    def self.next_version(project_id)
      where(project_id: project_id).max(:version).to_i + 1
    end

    def self.active_for_project(project_id)
      where(project_id: project_id, status: "active").order(Sequel.desc(:version)).first
    end

    def self.previous_deployable_for_project(project_id, excluding_release_id: nil)
      dataset = where(project_id: project_id, status: %w[active inactive])
      dataset = dataset.exclude(id: excluding_release_id) if excluding_release_id
      dataset.order(Sequel.desc(:version)).first
    end

    def before_validation
      self.status ||= "pending"
      self.version ||= self.class.next_version(project_id) if project_id
      super
    end

    def before_create
      self.id ||= SecureRandom.uuid
      self.created_at ||= Time.now.utc
      super
    end

    def validate
      super
      errors.add(:project_id, "is required") if project_id.nil? || project_id.to_s.empty?
      errors.add(:version, "is required") if version.nil?
      errors.add(:source_type, "must be one of: #{SOURCE_TYPES.join(", ")}") unless SOURCE_TYPES.include?(source_type)
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
      errors.add(:internal_port, "must be greater than 0") if internal_port && internal_port <= 0
      errors.add(:healthcheck_path, "must start with /") if healthcheck_path && !healthcheck_path.start_with?("/")
    end

    def activate!(activated_at: Time.now.utc)
      db.transaction do
        self.class.where(project_id: project_id, status: "active").exclude(id: id).update(status: "inactive")
        update(status: "active", activated_at: activated_at)
      end
    end

    def fail!
      update(status: "failed")
    end
  end
end
