# frozen_string_literal: true

require "securerandom"
require "sequel/model"
require "time"

module Valpo
  class Project < Sequel::Model(:projects)
    NAME_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/
    TYPES = %w[container static].freeze

    def self.find_by_id_or_name(id_or_name)
      where(id: id_or_name).first || where(name: id_or_name).first
    end

    def before_validation
      self.type ||= "container"
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= SecureRandom.uuid
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
      errors.add(:name, "is required") if name.nil? || name.strip.empty?
      errors.add(:name, "must use lowercase letters, numbers, and dashes") if name && !name.match?(NAME_PATTERN)
      errors.add(:type, "must be one of: #{TYPES.join(", ")}") unless TYPES.include?(type)
    end
  end
end
