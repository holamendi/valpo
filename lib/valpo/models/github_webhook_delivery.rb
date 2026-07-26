# frozen_string_literal: true

require "sequel/model"
require "time"

module Valpo
  class GitHubWebhookDelivery < Sequel::Model(:github_webhook_deliveries)
    unrestrict_primary_key

    def before_validation
      self.jobs_count ||= 0
      super
    end

    def before_create
      self.created_at ||= Time.now.utc
      super
    end

    def validate
      super
      errors.add(:id, "is required") if id.nil? || id.empty?
      errors.add(:event, "is required") if event.nil? || event.empty?
      errors.add(:payload_digest, "must be a SHA-256 digest") unless payload_digest&.match?(/\A[0-9a-f]{64}\z/)
      errors.add(:jobs_count, "must not be negative") if jobs_count&.negative?
    end
  end
end
