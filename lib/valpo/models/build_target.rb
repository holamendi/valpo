# frozen_string_literal: true

require "sequel/model"
require "time"
require "valpo/identifier"
require "valpo/models/project"
require "valpo/models/source"

module Valpo
  class BuildTarget < Sequel::Model(:build_targets)
    many_to_one :project
    many_to_one :source

    def before_validation
      self.dockerfile ||= "Dockerfile"
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
      errors.add(:source_id, "is required") if source_id.nil? || source_id.to_s.empty?
      source = Valpo::Source[source_id] if source_id
      errors.add(:source_id, "must belong to the same project") if source && source.project_id != project_id
      errors.add(:name, "must use lowercase letters, numbers, and dashes") unless name&.match?(Valpo::Project::NAME_PATTERN)
      errors.add(:dockerfile, "must be relative") if absolute_path?(dockerfile)
      errors.add(:context, "must be relative") if absolute_path?(context)
    end

    private

    def absolute_path?(value)
      return true if value.nil? || value.empty?

      path = Pathname.new(value)
      clean = path.cleanpath.to_s
      path.absolute? || clean == ".." || clean.start_with?("../")
    end
  end
end
