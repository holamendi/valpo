# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class VerifyPlatformDomain
        def initialize(orchestrator:)
          @orchestrator = orchestrator
        end

        def call(job, queue:)
          @orchestrator.configure_platform_domain(
            platform_domain_id: job.payload.fetch("platform_domain_id"), queue:, job_id: job[:id]
          )
        end
      end
    end
  end
end
