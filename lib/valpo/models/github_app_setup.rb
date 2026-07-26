# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class GitHubAppSetup < Sequel::Model(:github_app_setups)
    STATUSES = %w[pending completed].freeze

    def before_validation
      self.status ||= "pending"
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:github_app_setup)
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
      errors.add(:state_digest, "must be a SHA-256 digest") unless state_digest&.match?(/\A[0-9a-f]{64}\z/)
      errors.add(:app_domain, "must be a valid hostname") unless Valpo::Hostname.valid?(app_domain)
      if organization && !organization.match?(Valpo::GitHub::Setup::ORGANIZATION_PATTERN)
        errors.add(:organization, "must be a GitHub organization name")
      end
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
      errors.add(:expires_at, "is required") unless expires_at
    end

    def pending?(at: Time.now.utc)
      status == "pending" && expires_at > at
    end
  end
end
