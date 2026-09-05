# frozen_string_literal: true

require "json"
require "sequel/model"
require "time"

module Valpo
  class BuildTarget < Sequel::Model(:build_targets)
    STRATEGIES = Valpo::Builds::STRATEGIES

    many_to_one :project
    many_to_one :source
    many_to_one :owner_service, class: "Valpo::Service", key: :owner_service_id

    def before_validation
      self.strategy ||= dockerfile ? "dockerfile" : "auto"
      self.dockerfile ||= "Dockerfile" if strategy == "dockerfile"
      self.context ||= "."
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:build_target)
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
      errors.add(:source_id, "is required") if source_id.nil? || source_id.to_s.empty?
      source = Valpo::Source[source_id] if source_id
      errors.add(:source_id, "must belong to the same project") if source && source.project_id != project_id
      errors.add(:name, "must use lowercase letters, numbers, and dashes") unless name&.match?(Valpo::Project::NAME_PATTERN)
      errors.add(:strategy, "must be one of: #{STRATEGIES.join(", ")}") unless STRATEGIES.include?(strategy)
      if strategy == "dockerfile"
        errors.add(:dockerfile, "is required for dockerfile builds") if dockerfile.nil? || dockerfile.empty?
      elsif dockerfile
        errors.add(:dockerfile, "is only valid for dockerfile builds")
      end
      errors.add(:dockerfile, "must be relative") if dockerfile && invalid_relative_path?(dockerfile)
      errors.add(:context, "must be relative") if invalid_relative_path?(context)
      begin
        Valpo::Builds::BuildpackOptions.validate!(strategy:, builder:, buildpacks:)
      rescue Valpo::ValidationError, JSON::ParserError => e
        errors.add(:buildpacks, e.message)
      end
    end

    def buildpacks
      JSON.parse(buildpacks_json) if buildpacks_json
    end

    def buildpacks=(value)
      self.buildpacks_json = value.nil? ? nil : JSON.generate(value)
    end

    private

    def invalid_relative_path?(value)
      return true if value.nil? || value.empty?

      path = Pathname.new(value)
      clean = path.cleanpath.to_s
      path.absolute? || clean == ".." || clean.start_with?("../")
    end
  end
end
