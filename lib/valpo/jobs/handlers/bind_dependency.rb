# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class BindDependency
        def initialize(orchestrator:, method:)
          @orchestrator = orchestrator
          @method = method
        end

        def call(job, queue:)
          payload = job.payload
          @orchestrator.public_send(
            @method,
            service_id: payload.fetch("service_id"),
            dependency_service_id: payload.fetch("dependency_service_id"),
            queue:,
            job_id: job[:id]
          )
        end
      end
    end
  end
end
