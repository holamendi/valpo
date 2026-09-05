# frozen_string_literal: true

require "json"

module Valpo
  module Builds
    class Orchestrator
      def initialize(source_fetcher:, deployment_lifecycle:, builders:, target_lock:, preflight: nil)
        @deployment_lifecycle = deployment_lifecycle
        @builders = builders
        @target_lock = target_lock
        @preflight = preflight || Valpo::Sources::Preflight.new(fetcher: source_fetcher)
      end

      def deploy_source(service_id:, ref:, internal_port:, healthcheck_path:, queue:, job_id:)
        service = find_app_service(service_id)
        app_config = Valpo::AppServiceConfig[service.id]
        build_target = app_config&.build_target
        raise Valpo::ValidationError, "Service has no configured build target" unless build_target

        source = build_target.source
        selected_ref = blank_to_nil(ref) || source.ref
        preflight_succeeded = false
        event(queue, job_id, "system", "Fetching #{source.repository}@#{selected_ref}")
        preflight.with_checkout(
          provider: source.provider,
          repository: source.repository,
          ref: selected_ref,
          strategy: build_target.strategy,
          dockerfile: build_target.dockerfile,
          context: build_target.context
        ) do
          checkout = it
          preflight_succeeded = true
          source.update(status: "connected") unless source.status == "connected"
          deploy_checkout(
            service_id: service.id,
            build_target:,
            checkout:,
            internal_port:,
            healthcheck_path:,
            queue:,
            job_id:
          )
        end
      rescue
        source&.update(status: "failed") if !preflight_succeeded && source&.status != "failed"
        raise
      end

      def deploy_checkout(service_id:, build_target:, checkout:, internal_port:, healthcheck_path:, queue:, job_id:)
        service = find_app_service(service_id)
        image = image_tag(service.project, build_target, checkout.commit)
        event(queue, job_id, "system", "Building #{image} with #{checkout.strategy}")
        build_succeeded = false
        build_metadata = {}
        builder = builders.fetch(checkout.strategy) do
          raise Valpo::ValidationError, "Unsupported resolved build strategy: #{checkout.strategy}"
        end
        build_metadata = builder.initial_metadata(checkout:, build_target:)
        result = target_lock.synchronize(build_target.id) do
          builder.build(
            checkout:,
            build_target:,
            image:,
            service:,
            queue:,
            job_id:
          )
        end
        build_metadata = result.metadata
        build_succeeded = true
        deployment_lifecycle.deploy_built_image(
          service_id: service.id,
          image: result.image,
          source_ref: checkout.commit,
          build_target_id: build_target.id,
          build_strategy: result.strategy,
          build_metadata: result.metadata,
          internal_port:,
          healthcheck_path:,
          queue:,
          job_id:
        )
      rescue
        unless build_succeeded
          record_failed_build(
            service:,
            build_target:,
            checkout:,
            image:,
            build_strategy: checkout.strategy,
            build_metadata:,
            internal_port:,
            healthcheck_path:
          )
        end
        raise
      end

      private

      attr_reader :deployment_lifecycle, :preflight, :builders, :target_lock

      def find_app_service(service_id)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found: #{service_id}" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def image_tag(project, build_target, commit)
        "valpo/#{project.name}/#{build_target.name}:#{commit[0, 12]}"
      end

      def record_failed_build(service:, build_target:, checkout:, image:, build_strategy:, build_metadata:, internal_port:, healthcheck_path:)
        app_config = Valpo::AppServiceConfig[service.id]
        old_active = Valpo::Release.active_for_service(service.id)
        Valpo::Release.create(
          service_id: service.id,
          build_target_id: build_target.id,
          source_type: "git",
          source_ref: checkout.commit,
          artifact_ref: image,
          build_strategy:,
          build_metadata_json: JSON.generate(build_metadata),
          status: "failed",
          internal_port: internal_port || app_config&.internal_port,
          healthcheck_path: blank_to_nil(healthcheck_path) || app_config&.healthcheck_path
        )
        service.transition_to!(old_active ? "running" : "failed")
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end

      def blank_to_nil(value)
        (value.nil? || value.to_s.empty?) ? nil : value
      end
    end
  end
end
