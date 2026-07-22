# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class VerifyDomain
        def initialize(orchestrator:)
          @orchestrator = orchestrator
        end

        def call(job, queue:)
          @orchestrator.verify_domain(
            domain_id: job.payload.fetch("domain_id"), queue:, job_id: job[:id]
          )
        end
      end
    end
  end
end
