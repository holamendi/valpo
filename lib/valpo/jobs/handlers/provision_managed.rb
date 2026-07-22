# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class ProvisionManaged
        def initialize(orchestrator:)
          @orchestrator = orchestrator
        end

        def call(job, queue:)
          @orchestrator.provision_service(
            service_id: job.payload.fetch("service_id"), queue:, job_id: job[:id]
          )
        end
      end
    end
  end
end
