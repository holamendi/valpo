# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class AppOperation
        def initialize(orchestrator:, method:)
          @orchestrator = orchestrator
          @method = method
        end

        def call(job, queue:)
          @orchestrator.public_send(
            @method,
            service_id: job.payload.fetch("service_id"),
            queue:,
            job_id: job[:id]
          )
        end
      end
    end
  end
end
