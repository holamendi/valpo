# frozen_string_literal: true

require "securerandom"
require "sequel/model"
require "time"

module Valpo
  class Domain < Sequel::Model(:domains)
    HOSTNAME_PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

    many_to_one :project

    def before_validation
      self.hostname = hostname.downcase if hostname
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= SecureRandom.uuid
      self.tls_status ||= "unknown"
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
      errors.add(:hostname, "is required") if hostname.nil? || hostname.strip.empty?
      errors.add(:hostname, "must be a valid lowercase hostname") if hostname && !hostname.match?(HOSTNAME_PATTERN)
    end
  end
end
