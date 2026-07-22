# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class UpdateApp
        def initialize(updater:)
          @updater = updater
        end

        def call(job, queue:)
          payload = job.payload
          @updater.update(
            service_id: payload.fetch("service_id"),
            configuration: payload["configuration"],
            runtime_changes: payload.fetch("runtime", {}),
            deploy: payload.fetch("deploy", false),
            queue:,
            job_id: job.id
          )
        end
      end
    end
  end
end
