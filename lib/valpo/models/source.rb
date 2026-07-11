# frozen_string_literal: true

require "sequel/model"
require "time"
require "valpo/identifier"
require "valpo/models/project"

module Valpo
  class Source < Sequel::Model(:sources)
    PROVIDERS = %w[github].freeze
    STATUSES = %w[unconnected connected failed].freeze

    many_to_one :project
    one_to_many :build_targets

    def before_validation
      self.ref ||= "main"
      self.status ||= "unconnected"
      self.auto_deploy = false if auto_deploy.nil?
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:source)
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
      errors.add(:name, "must use lowercase letters, numbers, and dashes") unless name&.match?(Valpo::Project::NAME_PATTERN)
      errors.add(:provider, "must be one of: #{PROVIDERS.join(", ")}") unless PROVIDERS.include?(provider)
      errors.add(:repository, "is required") if repository.nil? || repository.strip.empty?
      errors.add(:ref, "is required") if ref.nil? || ref.strip.empty?
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
    end
  end
end
