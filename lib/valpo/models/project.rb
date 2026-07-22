# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class Project < Sequel::Model(:projects)
    NAME_PATTERN = Valpo::Hostname::LABEL_PATTERN

    one_to_many :services
    one_to_many :sources
    one_to_many :build_targets

    def self.find_by_id_or_name(value)
      where(id: value).first || where(name: value).first
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:project)
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
      errors.add(:name, "must be a DNS-safe label of up to 63 lowercase letters, numbers, and dashes") if name && !name.match?(NAME_PATTERN)
    end
  end
end
