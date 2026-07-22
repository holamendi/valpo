# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class DeployRegistryImage
        def initialize(orchestrator:)
          @orchestrator = orchestrator
        end

        def call(job, queue:)
          payload = job.payload
          @orchestrator.deploy_registry_image(
            service_id: payload.fetch("service_id"),
            image: payload.fetch("image"),
            internal_port: payload["internal_port"] && Integer(payload["internal_port"]),
            healthcheck_path: payload["healthcheck_path"],
            queue:,
            job_id: job[:id]
          )
        end
      end
    end
  end
end
