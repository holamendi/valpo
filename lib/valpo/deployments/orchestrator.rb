# frozen_string_literal: true

module Valpo
  module Deployments
    class Orchestrator
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        caddy: Valpo::Caddy::Client.new(config_path: config.caddy_config_path, reload_config_path: config.caddy_reload_config_path),
        health_checker: HealthChecker.new,
        service_orchestrator: nil,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @caddy = caddy
        @health_checker = health_checker
        @service_orchestrator = service_orchestrator
        @sleeper = sleeper
      end

      def deploy_registry_image(service_id:, image:, internal_port:, healthcheck_path:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        app_config = Valpo::AppServiceConfig[service.id]
        port = internal_port || app_config&.internal_port
        raise Valpo::ValidationError, "internal_port is required for web services" if service.web? && port.nil?

        old_active = Valpo::Release.active_for_service(service.id)
        release = nil
        container_name = nil

        service.update(status: "provisioning")
        event(queue, job_id, "system", "Pulling #{image}")
        runtime.pull_image(image)
        digest = runtime.inspect_image_digest(image)
        release = Valpo::Release.create(
          service_id: service.id,
          build_target_id: app_config&.build_target_id,
          source_type: "registry",
          source_ref: image,
          artifact_ref: digest || image,
          image_digest: digest,
          internal_port: port,
          healthcheck_path: blank_to_nil(healthcheck_path) || app_config&.healthcheck_path
        )

        container_name = runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: release)
        release.activate!
        service.update(status: "running")
        retire_container(old_active, runtime)
        release.refresh
      rescue
        release&.fail!
        runtime&.cleanup_container(container_name)
        service&.update(status: old_active ? "running" : "failed")
        raise
      end

      def rollback_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        current = Valpo::Release.active_for_service(service.id)
        target = Valpo::Release.previous_deployable_for_service(service.id, excluding_release_id: current&.id)
        raise Valpo::ValidationError, "No previous release is available for rollback" unless target

        previous_container = target.container_name
        previous_route_target = target.route_target
        new_container = nil
        service.update(status: "provisioning")
        new_container = runtime.start_release_container(target)
        wait_for_release(target, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: target)
        target.activate!
        service.update(status: "running")
        retire_container(current, runtime)
        target.refresh
      rescue
        runtime&.cleanup_container(new_container)
        target&.update(container_name: previous_container, route_target: previous_route_target)
        service&.update(status: current ? "running" : "failed")
        raise
      end

      def stop_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        active = Valpo::Release.active_for_service(service.id)
        if active&.container_name
          runtime.stop_container(active.container_name, ignore_missing: true)
          active.update(container_name: nil, route_target: nil)
        end
        service.update(status: "stopped")
        apply_caddy_config(queue: queue, job_id: job_id)
        service
      end

      def restart_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        active = Valpo::Release.active_for_service(service.id)
        raise Valpo::ValidationError, "No active release is available to restart" unless active

        old_container = active.container_name
        previous_route_target = active.route_target
        new_container = nil
        service.update(status: "restarting")
        new_container = runtime.start_release_container(active)
        wait_for_release(active, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: active)
        service.update(status: "running")
        runtime.stop_container(old_container, ignore_missing: true) if old_container && old_container != new_container
        active.refresh
      rescue
        runtime&.cleanup_container(new_container)
        active&.update(container_name: old_container, route_target: previous_route_target)
        service&.update(status: active ? "running" : "failed")
        raise
      end

      def delete_app_service(service_id:, force:, queue:, job_id:)
        raise Valpo::ValidationError, "force=true is required to delete a service" unless force

        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        service_name = service.name
        service.update(status: "deleting")
        apply_caddy_config(queue: queue, job_id: job_id, exclude_service_id: service.id)
        Valpo::Release.where(service_id: service.id).exclude(container_name: nil).select_map(:container_name).uniq.each do |name|
          runtime.stop_container(name, ignore_missing: true)
        end
        service.destroy
        event(queue, job_id, "system", "Deleted #{service_name}")
        true
      end

      def delete_project(project_id:, queue:, job_id:)
        project = Valpo::Project[project_id]
        raise Valpo::ValidationError, "Project not found: #{project_id}" unless project
        raise Valpo::ConflictError, "Project still has services" unless Valpo::Service.where(project_id: project.id).empty?

        project_name = project.name
        project.destroy
        apply_caddy_config(queue: queue, job_id: job_id)
        event(queue, job_id, "system", "Deleted #{project_name}")
        true
      end

      def repair_system(queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        event(queue, job_id, "system", "Repairing system state")
        service_orchestrator_for.repair_services(queue: queue, job_id: job_id)
        repair_active_containers(runtime, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id)
        true
      end

      def apply_caddy_config(queue:, job_id:, override_release: nil, exclude_service_id: nil)
        route_projector_for(queue: queue, job_id: job_id).apply(
          override_release: override_release,
          exclude_service_id: exclude_service_id
        )
      end

      def app_logs(service_id:, tail: nil)
        service = find_app_service(service_id)
        active = Valpo::Release.active_for_service(service.id)
        raise Valpo::ValidationError, "No active release is available for logs" unless active&.container_name

        runtime_for.app_logs(container_name: active.container_name, tail: tail)
      end

      private

      attr_reader :config, :docker, :caddy, :health_checker, :service_orchestrator, :sleeper

      def find_app_service(service_id)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found: #{service_id}" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def wait_for_release(release, queue:, job_id:)
        return unless release.internal_port

        event(queue, job_id, "system", "Waiting for health check on #{release.route_target}")
        health_checker.wait(route_target: release.route_target, path: release.healthcheck_path, timeout: config.healthcheck_timeout)
      end

      def repair_active_containers(runtime, queue:, job_id:)
        Valpo::Service.where(kind: Valpo::Service::APP_KINDS).exclude(status: "stopped").order(:name).each do |service|
          release = Valpo::Release.active_for_service(service.id)
          next unless release

          repair_release_container(service, release, runtime, queue: queue, job_id: job_id)
        end
      end

      def repair_release_container(service, release, runtime, queue:, job_id:)
        inspection = runtime.inspect_container(release.container_name) if release.container_name
        if inspection && (release.route_target || !service.web?)
          runtime.update_restart_policy(release.container_name)
          unless inspection.dig("State", "Running")
            event(queue, job_id, "system", "Starting #{release.container_name}")
            runtime.start_container(release.container_name)
            wait_for_release(release, queue: queue, job_id: job_id)
          end
          service.update(status: "running") unless service.status == "running"
          return
        end

        if inspection
          runtime.stop_container(release.container_name, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end
        event(queue, job_id, "system", "Recreating runtime for #{service.name}")
        runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        service.update(status: "running")
      end

      def retire_container(release, runtime)
        return unless release&.container_name

        runtime.stop_container(release.container_name, ignore_missing: true)
        release.update(container_name: nil, route_target: nil)
      end

      def runtime_for(queue: nil, job_id: nil)
        Runtime.new(config: config, docker: docker, queue: queue, job_id: job_id, sleeper: sleeper)
      end

      def route_projector_for(queue:, job_id:)
        RouteProjector.new(caddy: caddy, queue: queue, job_id: job_id)
      end

      def service_orchestrator_for
        return service_orchestrator if service_orchestrator

        Valpo::Services::Orchestrator.new(config: config, docker: docker, sleeper: sleeper)
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
