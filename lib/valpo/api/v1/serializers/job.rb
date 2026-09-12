# frozen_string_literal: true

require "json"

module Valpo
  module API
    module V1
      module Serializers
        class Job < Serializer
          fields :id, :type, :status, :progress, :error, :project_id, :project_name,
            :service_id, :related_service_id, :idempotency_key, :request_fingerprint,
            :attempt, :operation_generation, :recovery_strategy, :checkpoint, :recovery_action,
            :reconciliation_job_id, :resolved_at, :locked_by, :locked_at, :heartbeat_at,
            :started_at, :finished_at, :created_at

          field(:payload) { JSON.parse(it[:payload_json] || "{}") }
        end
      end
    end
  end
end
