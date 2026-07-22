# frozen_string_literal: true

require "json"

module Valpo
  module API
    module V1
      module Jobs
        module_function

        def render(job)
          Fields.call(
            job, :id, :type, :status, :progress, :error, :locked_by, :locked_at, :started_at, :finished_at, :created_at
          ).merge(payload: JSON.parse(job[:payload_json] || "{}"))
        end

        def render_event(event)
          Fields.call(event, :id, :job_id, :stream, :message, :created_at)
        end
      end
    end
  end
end
