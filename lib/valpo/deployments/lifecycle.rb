# frozen_string_literal: true

require "json"

module Valpo
  module Deployments
    class Lifecycle
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        caddy: Valpo::Caddy::Client.new(
          config_path: config.caddy_config_path,
          reload_config_path: config.caddy_reload_config_path
        ),
        health_checker: HealthChecker.new,
        port_resolver: PortResolver.new,
        domain_verifier: Valpo::Domains::ReachabilityVerifier.new,
        caddy_reconciler: nil,
        activator: nil,
        domain_orchestrator: nil,
        build_cache_manager: nil,
        image_cleaner: nil,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @health_checker = health_checker
        @port_resolver = port_resolver
        @sleeper = sleeper
        @caddy_reconciler = caddy_reconciler || Valpo::Caddy::Reconciler.new(caddy:)
        @activator = activator || Activator.new(caddy_reconciler: @caddy_reconciler)
        @domain_orchestrator = domain_orchestrator || Valpo::Domains::Orchestrator.new(
          caddy_reconciler: @caddy_reconciler,
          activator: @activator,
          config:,
          docker:,
          verifier: domain_verifier,
          sleeper:
        )
        @build_cache_manager = build_cache_manager
        @image_cleaner = image_cleaner || Valpo::Storage::ImageCleaner.new(
          docker:,
          retention_count: config.image_retention_count,
          grace_period: config.storage_cleanup_grace_period
        )
      end

      def deploy_registry_image(service_id:, image:, internal_port:, healthcheck_path:, queue:, job_id:)
        deploy_image(
          service_id:,
          image:,
          source_type: "registry",
          source_ref: image,
          build_target_id: nil,
          build_strategy: nil,
          build_metadata: {},
          internal_port:,
          healthcheck_path:,
          pull: true,
          queue:,
          job_id:
        )
      end

      def deploy_built_image(service_id:, image:, source_ref:, build_target_id:, build_strategy:, build_metadata:, internal_port:, healthcheck_path:, queue:, job_id:)
        deploy_image(
          service_id:,
          image:,
          source_type: "git",
          source_ref:,
          build_target_id:,
          build_strategy:,
          build_metadata:,
          internal_port:,
          healthcheck_path:,
          pull: false,
          queue:,
          job_id:
        )
      end

      def rollback_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        service = find_app_service(service_id)
        current = Valpo::Release.active_for_service(service.id)
        target = Valpo::Release.previous_deployable_for_service(service.id, excluding_release_id: current&.id)
        raise Valpo::ValidationError, "No previous release is available for rollback" unless target

        previous_container = target.container_name
        previous_route_target = target.route_target
        domain_orchestrator.ensure_verified!(service)
        new_container = nil
        service.update(status: "provisioning")
        new_container = runtime.start_release_container(target)
        wait_for_release(target, queue:, job_id:)
        activator.activate(
          service:,
          release: target,
          runtime:,
          queue:,
          job_id:,
          retire: [current]
        )
        target.update(environment_revision: service.environment_revision)
        target.refresh
      rescue
        runtime&.cleanup_container(new_container)
        target&.refresh
        service&.refresh
        target&.update(container_name: previous_container, route_target: previous_route_target)
        service&.update(status: current ? "running" : "failed")
        raise
      end

      def stop_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        service = find_app_service(service_id)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        if release&.container_name
          runtime.stop_container(release.container_name, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end
        service.update(status: "stopped")
        activator.apply_routes(queue:, job_id:)
        service
      end

      def restart_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        service = find_app_service(service_id)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        raise Valpo::ValidationError, "No active or ready release is available to restart" unless release

        old_container = release.container_name
        previous_route_target = release.route_target
        new_container = nil
        service.update(status: "restarting")
        new_container = runtime.start_release_container(release)
        wait_for_release(release, queue:, job_id:)
        if service.web? && !domain_orchestrator.verified?(service)
          release.ready!
          service.update(status: "ready")
          activator.apply_routes(queue:, job_id:)
        else
          activator.activate(
            service:,
            release:,
            runtime:,
            queue:,
            job_id:,
            on_failure: -> { release.update(container_name: old_container, route_target: previous_route_target) }
          )
        end
        retire_container_safely(old_container, runtime, queue:, job_id:) if old_container && old_container != new_container
        release.update(environment_revision: service.environment_revision)
        release.refresh
      rescue
        runtime&.cleanup_container(new_container)
        release&.refresh
        service&.refresh
        release&.update(container_name: old_container, route_target: previous_route_target)
        status = if release.nil?
          "failed"
        elsif release.status == "ready"
          "ready"
        else
          "running"
        end
        service&.update(status:)
        raise
      end

      def reconfigure_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        service = find_app_service(service_id)
        active = Valpo::Release.active_for_service(service.id)
        raise Valpo::ValidationError, "No active release is available to reconfigure" unless active

        app_config = Valpo::AppServiceConfig[service.id]
        previous = active.values.slice(:internal_port, :healthcheck_path)
        image_metadata = if service.web? && app_config.internal_port.nil?
          runtime.inspect_image_metadata(active.artifact_ref || active.source_ref)
        else
          Valpo::Deployments::ImageMetadata.new(digest: active.image_digest, exposed_tcp_ports: [])
        end
        port = port_resolver.resolve(
          service:,
          explicit_port: app_config.internal_port,
          source_type: active.source_type,
          image_metadata:
        )
        active.update(internal_port: port, healthcheck_path: app_config.healthcheck_path)
        restart_service(service_id: service.id, queue:, job_id:)
      rescue
        active&.update(previous) if active && previous
        raise
      end

      def delete_app_service(service_id:, force:, queue:, job_id:)
        raise Valpo::ValidationError, "force=true is required to delete a service" unless force

        runtime = runtime_for(queue:, job_id:)
        service = find_app_service(service_id)
        service_name = service.name
        service.update(status: "deleting")
        activator.apply_routes(queue:, job_id:, exclude_service_id: service.id)
        Valpo::Release.where(service_id: service.id).exclude(container_name: nil).select_map(:container_name).uniq.each do
          runtime.stop_container(it, ignore_missing: true)
        end
        build_target_ids = Valpo::BuildTarget.where(owner_service_id: service.id).select_map(:id)
        remove_build_caches(build_target_ids, queue:, job_id:)
        image_cleaner.remove_for_service(service_id: service.id, queue:, job_id:)
        service.destroy
        event(queue, job_id, "Deleted #{service_name}")
        true
      end

      def delete_project(project_id:, queue:, job_id:)
        project = Valpo::Project[project_id]
        raise Valpo::ValidationError, "Project not found: #{project_id}" unless project
        raise Valpo::ConflictError, "Project still has services" unless Valpo::Service.where(project_id: project.id).empty?

        project_name = project.name
        build_target_ids = Valpo::BuildTarget.where(project_id: project.id).select_map(:id)
        remove_build_caches(build_target_ids, queue:, job_id:)
        project.destroy
        activator.apply_routes(queue:, job_id:)
        event(queue, job_id, "Deleted #{project_name}")
        true
      end

      def app_logs(service_id:, tail: nil)
        service = find_app_service(service_id)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        raise Valpo::ValidationError, "No active or ready release is available for logs" unless release&.container_name

        runtime_for.app_logs(container_name: release.container_name, tail:)
      end

      private

      attr_reader :config, :docker, :health_checker, :port_resolver, :domain_orchestrator, :activator, :build_cache_manager, :image_cleaner, :sleeper

      def deploy_image(service_id:, image:, source_type:, source_ref:, build_target_id:, build_strategy:, build_metadata:, internal_port:, healthcheck_path:, pull:, queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        service = find_app_service(service_id)
        app_config = Valpo::AppServiceConfig[service.id]
        configured_port = internal_port || app_config&.internal_port
        old_active = Valpo::Release.active_for_service(service.id)
        old_ready = Valpo::Release.ready_for_service(service.id)
        release = nil
        container_name = nil

        service.update(status: "provisioning")
        if pull
          event(queue, job_id, "Pulling #{image}")
          runtime.pull_image(image)
        else
          event(queue, job_id, "Deploying built image #{image}")
        end
        image_metadata = runtime.inspect_image_metadata(image)
        port = port_resolver.resolve(
          service:,
          explicit_port: configured_port,
          source_type:,
          image_metadata:
        )
        digest = image_metadata.digest
        release = Valpo::Release.create(
          service_id: service.id,
          build_target_id: build_target_id || app_config&.build_target_id,
          source_type:,
          source_ref:,
          artifact_ref: digest || image,
          image_digest: digest,
          build_strategy:,
          build_metadata_json: JSON.generate(build_metadata),
          environment_revision: service.environment_revision,
          internal_port: port,
          healthcheck_path: blank_to_nil(healthcheck_path) || app_config&.healthcheck_path
        )

        container_name = runtime.start_release_container(release)
        wait_for_release(release, queue:, job_id:)
        if service.web? && !domain_orchestrator.verified?(service)
          domain_orchestrator.verify_service_domains(service, queue:, job_id:)
        end
        if service.web? && !domain_orchestrator.verified?(service)
          release.ready!
          service.update(status: old_active ? "running" : "ready")
          retire_release_safely(old_ready, runtime, queue:, job_id:)
          event(queue, job_id, "Release is ready but remains private until a domain is verified")
        else
          activator.activate(
            service:,
            release:,
            runtime:,
            queue:,
            job_id:,
            retire: [old_active, old_ready]
          )
        end
        release.refresh
      rescue
        release&.refresh
        service&.refresh
        release&.fail!
        cleaned = runtime&.cleanup_container(container_name)
        release&.update(container_name: nil, route_target: nil) if cleaned
        service&.update(status: old_active ? "running" : "failed")
        raise
      end

      def find_app_service(service_id)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found: #{service_id}" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def wait_for_release(release, queue:, job_id:)
        return unless release.internal_port

        event(queue, job_id, "Waiting for health check on #{release.route_target}")
        health_checker.wait(
          route_target: release.route_target,
          path: release.healthcheck_path,
          timeout: config.healthcheck_timeout
        )
      end

      def runtime_for(queue: nil, job_id: nil)
        Runtime.new(config:, docker:, queue:, job_id:, sleeper:)
      end

      def event(queue, job_id, message, stream: "system")
        queue.event(job_id, stream, message)
      end

      def blank_to_nil(value)
        (value.nil? || value.to_s.empty?) ? nil : value
      end

      def remove_build_caches(build_target_ids, queue:, job_id:)
        return unless build_cache_manager

        build_target_ids.each do
          build_cache_manager.remove(build_target_id: it, queue:, job_id:)
        end
      end

      def retire_container_safely(container_name, runtime, queue:, job_id:)
        runtime.stop_container(container_name, ignore_missing: true)
      rescue => e
        event(queue, job_id, "Could not retire container #{container_name}: #{e.message}", stream: "stderr")
      end

      def retire_release_safely(release, runtime, queue:, job_id:)
        activator.retire_release(release, runtime)
      rescue => e
        event(queue, job_id, "Could not retire release #{release.version}: #{e.message}", stream: "stderr")
      end
    end
  end
end
