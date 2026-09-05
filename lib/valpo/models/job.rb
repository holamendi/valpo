# frozen_string_literal: true

require "json"
require "sequel/model"
require "time"

module Valpo
  class Job < Sequel::Model(:jobs)
    include Valpo::LifecycleTransitions

    STATUSES = %w[queued running succeeded failed].freeze
    TRANSITIONS = {
      "queued" => %w[running],
      "running" => %w[queued succeeded failed],
      "succeeded" => [],
      "failed" => %w[queued]
    }.freeze

    def payload
      JSON.parse(payload_json || "{}")
    end

    def before_validation
      self.status ||= "queued"
      self.progress ||= 0
      super
    end

    def before_create
      self.id ||= Valpo::Identifier.generate(:job)
      self.created_at ||= Time.now.utc
      super
    end

    def validate
      super
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
    end
  end
end
