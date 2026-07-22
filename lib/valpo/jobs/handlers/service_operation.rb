# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class ServiceOperation
        def initialize(deployment_lifecycle:, managed_lifecycle:, operation:)
          @deployment_lifecycle = deployment_lifecycle
          @managed_lifecycle = managed_lifecycle
          @operation = operation
        end

        def call(job, queue:)
          payload = job.payload
          service = Valpo::Service[payload.fetch("service_id")] ||
            raise(Valpo::ValidationError, "Service not found")
          lifecycle = service.app? ? @deployment_lifecycle : @managed_lifecycle
          method = (service.app? && @operation == :delete_service) ? :delete_app_service : @operation
          arguments = {service_id: service.id, queue:, job_id: job[:id]}
          arguments[:force] = payload.fetch("force", false) if @operation == :delete_service
          lifecycle.public_send(method, **arguments)
        end
      end
    end
  end
end
