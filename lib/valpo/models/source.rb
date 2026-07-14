# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class Source < Sequel::Model(:sources)
    PROVIDERS = %w[github].freeze
    STATUSES = %w[unconnected connected failed].freeze

    many_to_one :project
    many_to_one :owner_service, class: "Valpo::Service", key: :owner_service_id
    one_to_many :build_targets

    def before_validation
      self.ref ||= "HEAD"
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
      owner = Valpo::Service[owner_service_id] if owner_service_id
      errors.add(:owner_service_id, "must reference an app service in the same project") if owner && (!owner.app? || owner.project_id != project_id)
      errors.add(:name, "must use lowercase letters, numbers, and dashes") unless name&.match?(Valpo::Project::NAME_PATTERN)
      errors.add(:provider, "must be one of: #{PROVIDERS.join(", ")}") unless PROVIDERS.include?(provider)
      errors.add(:repository, "is required") if repository.nil? || repository.strip.empty?
      if provider == "github" && !repository.to_s.match?(Valpo::Sources::GitHub::REPOSITORY_PATTERN)
        errors.add(:repository, "must be a GitHub owner/repository name")
      end
      errors.add(:ref, "is required") if ref.nil? || ref.strip.empty?
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
    end
  end
end
