# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class CreateSource
        def initialize(preflight:, configurator:, builds:)
          @preflight = preflight
          @configurator = configurator
          @builds = builds
        end

        def call(job, queue:)
          payload = job.payload
          project = Valpo::Project[payload.fetch("project_id")] ||
            raise(Valpo::ValidationError, "Project not found")
          source = payload.fetch("source")
          build = payload.fetch("build")
          service_attributes = payload.fetch("service")
          queue.event(job.id, "system", "Validating #{source.fetch("repository")}@#{source.fetch("ref")}")

          preflight.with_checkout(
            provider: source.fetch("provider"),
            repository: source.fetch("repository"),
            ref: source.fetch("ref"),
            dockerfile: build.fetch("dockerfile"),
            context: build.fetch("context")
          ) do
            checkout = it
            service = configurator.create_service!(
              project:,
              service_attributes:,
              source:,
              build:
            )
            queue.event(job.id, "system", "Configured #{project.name}/#{service.name} at #{checkout.commit}")
            next unless payload["deploy"]

            builds.deploy_checkout(
              service_id: service.id,
              build_target: Valpo::AppServiceConfig[service.id].build_target,
              checkout:,
              internal_port: nil,
              healthcheck_path: nil,
              queue:,
              job_id: job.id
            )
          end
        end

        private

        attr_reader :preflight, :configurator, :builds
      end
    end
  end
end
