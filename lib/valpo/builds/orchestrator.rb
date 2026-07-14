# frozen_string_literal: true

module Valpo
  module Builds
    class Orchestrator
      def initialize(docker:, source_fetcher:, deployment_orchestrator:, preflight: nil)
        @docker = docker
        @deployment_orchestrator = deployment_orchestrator
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
          dockerfile: build_target.dockerfile,
          context: build_target.context
        ) do |checkout|
          preflight_succeeded = true
          source.update(status: "connected") unless source.status == "connected"
          deploy_checkout(
            service_id: service.id,
            build_target: build_target,
            checkout: checkout,
            internal_port: internal_port,
            healthcheck_path: healthcheck_path,
            queue: queue,
            job_id: job_id
          )
        end
      rescue
        source&.update(status: "failed") if !preflight_succeeded && source&.status != "failed"
        raise
      end

      def deploy_checkout(service_id:, build_target:, checkout:, internal_port:, healthcheck_path:, queue:, job_id:)
        service = find_app_service(service_id)
        image = image_tag(service.project, build_target, checkout.commit)
        event(queue, job_id, "system", "Building #{image}")
        build_succeeded = false
        execute_build(
          dockerfile: checkout.dockerfile,
          context: checkout.context,
          image: image,
          queue: queue,
          job_id: job_id
        )
        build_succeeded = true
        deployment_orchestrator.deploy_built_image(
          service_id: service.id,
          image: image,
          source_ref: checkout.commit,
          build_target_id: build_target.id,
          internal_port: internal_port,
          healthcheck_path: healthcheck_path,
          queue: queue,
          job_id: job_id
        )
      rescue
        unless build_succeeded
          record_failed_build(
            service: service,
            build_target: build_target,
            checkout: checkout,
            image: image,
            internal_port: internal_port,
            healthcheck_path: healthcheck_path
          )
        end
        raise
      end

      private

      attr_reader :docker, :deployment_orchestrator, :preflight

      def find_app_service(service_id)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found: #{service_id}" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def image_tag(project, build_target, commit)
        "valpo/#{project.name}/#{build_target.name}:#{commit[0, 12]}"
      end

      def execute_build(dockerfile:, context:, image:, queue:, job_id:)
        result = docker.execute(docker.build_command(dockerfile: dockerfile, tag: image, context: context))
        emit_result(result, queue: queue, job_id: job_id)
        return if result.fetch(:success)

        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "Docker build failed: #{detail}"
      end

      def record_failed_build(service:, build_target:, checkout:, image:, internal_port:, healthcheck_path:)
        app_config = Valpo::AppServiceConfig[service.id]
        old_active = Valpo::Release.active_for_service(service.id)
        Valpo::Release.create(
          service_id: service.id,
          build_target_id: build_target.id,
          source_type: "git",
          source_ref: checkout.commit,
          artifact_ref: image,
          status: "failed",
          internal_port: internal_port || app_config&.internal_port,
          healthcheck_path: blank_to_nil(healthcheck_path) || app_config&.healthcheck_path
        )
        service.update(status: old_active ? "running" : "failed")
      end

      def emit_result(result, queue:, job_id:)
        stdout = result.fetch(:stdout).to_s.strip
        stderr = result.fetch(:stderr).to_s.strip
        event(queue, job_id, "stdout", stdout) unless stdout.empty?
        event(queue, job_id, "stderr", stderr) unless stderr.empty?
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
