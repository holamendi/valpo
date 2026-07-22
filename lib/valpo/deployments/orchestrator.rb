# frozen_string_literal: true

require "securerandom"
require "time"

module Valpo
  module Deployments
    class Orchestrator
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        caddy: Valpo::Caddy::Client.new(config_path: config.caddy_config_path, reload_config_path: config.caddy_reload_config_path),
        health_checker: HealthChecker.new,
        port_resolver: PortResolver.new,
        domain_verifier: Valpo::Domains::ReachabilityVerifier.new,
        service_orchestrator: nil,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @caddy = caddy
        @health_checker = health_checker
        @port_resolver = port_resolver
        @domain_verifier = domain_verifier
        @service_orchestrator = service_orchestrator
        @sleeper = sleeper
      end

      def deploy_registry_image(service_id:, image:, internal_port:, healthcheck_path:, queue:, job_id:)
        deploy_image(
          service_id: service_id,
          image: image,
          source_type: "registry",
          source_ref: image,
          build_target_id: nil,
          internal_port: internal_port,
          healthcheck_path: healthcheck_path,
          pull: true,
          queue: queue,
          job_id: job_id
        )
      end

      def deploy_built_image(service_id:, image:, source_ref:, build_target_id:, internal_port:, healthcheck_path:, queue:, job_id:)
        deploy_image(
          service_id: service_id,
          image: image,
          source_type: "git",
          source_ref: source_ref,
          build_target_id: build_target_id,
          internal_port: internal_port,
          healthcheck_path: healthcheck_path,
          pull: false,
          queue: queue,
          job_id: job_id
        )
      end

      def rollback_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        current = Valpo::Release.active_for_service(service.id)
        target = Valpo::Release.previous_deployable_for_service(service.id, excluding_release_id: current&.id)
        raise Valpo::ValidationError, "No previous release is available for rollback" unless target
        previous_container = target.container_name
        previous_route_target = target.route_target
        ensure_verified_domain!(service)

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
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        if release&.container_name
          runtime.stop_container(release.container_name, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end
        service.update(status: "stopped")
        apply_caddy_config(queue: queue, job_id: job_id)
        service
      end

      def restart_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        raise Valpo::ValidationError, "No active or ready release is available to restart" unless release

        old_container = release.container_name
        previous_route_target = release.route_target
        new_container = nil
        service.update(status: "restarting")
        new_container = runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        if service.web? && !verified_domain?(service)
          release.ready!
          service.update(status: "ready")
          apply_caddy_config(queue: queue, job_id: job_id)
        else
          apply_caddy_config(queue: queue, job_id: job_id, override_release: release)
          release.activate! unless release.status == "active"
          service.update(status: "running")
        end
        runtime.stop_container(old_container, ignore_missing: true) if old_container && old_container != new_container
        release.refresh
      rescue
        runtime&.cleanup_container(new_container)
        release&.update(container_name: old_container, route_target: previous_route_target)
        status = if release.nil?
          "failed"
        elsif release.status == "ready"
          "ready"
        else
          "running"
        end
        service&.update(status: status)
        raise
      end

      def reconfigure_service(service_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
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
          service: service,
          explicit_port: app_config.internal_port,
          source_type: active.source_type,
          image_metadata: image_metadata
        )
        active.update(internal_port: port, healthcheck_path: app_config.healthcheck_path)
        restart_service(service_id: service.id, queue: queue, job_id: job_id)
      rescue
        active&.update(previous) if active && previous
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

      def configure_platform_domain(platform_domain_id:, queue:, job_id:)
        record = Valpo::PlatformDomain[platform_domain_id]
        raise Valpo::ValidationError, "App domain not found: #{platform_domain_id}" unless record

        event(queue, job_id, "system", "Verifying wildcard DNS for *.#{record.hostname}")
        verify_challenge!(hostname: record.verification_hostname, token: record.verification_token, queue: queue, job_id: job_id)
        Valpo::Domains::Configuration.activate!(record)
        failures = []
        Valpo::Domain.where(platform_domain_id: record.id).order(:hostname).each do |domain|
          if domain.verified?
            Valpo::Domains::Configuration.retire_stale_generated!(domain.service, keep: domain)
            activate_ready_release(domain.service, queue: queue, job_id: job_id)
          else
            verify_domain_record(domain, queue: queue, job_id: job_id, activate_ready: true)
          end
        rescue Valpo::ValidationError => e
          failures << e.message
        end
        apply_caddy_config(queue: queue, job_id: job_id)
        raise Valpo::ValidationError, failures.join("; ") unless failures.empty?

        record.refresh
      rescue => e
        if record && !record.verified?
          record.update(status: "failed", active: false, verification_error: e.message, verified_at: nil)
        end
        safely_apply_caddy_config(queue: queue, job_id: job_id)
        raise
      end

      def verify_domain(domain_id:, queue:, job_id:)
        domain = Valpo::Domain[domain_id]
        raise Valpo::ValidationError, "Domain not found: #{domain_id}" unless domain

        domain.update(
          status: "pending",
          verification_token: SecureRandom.hex(24),
          verification_error: nil,
          verified_at: nil
        )
        verify_domain_record(domain, queue: queue, job_id: job_id, activate_ready: true)
      end

      def apply_caddy_config(queue:, job_id:, override_release: nil, exclude_service_id: nil, extra_routes: [])
        route_projector_for(queue: queue, job_id: job_id).apply(
          override_release: override_release,
          exclude_service_id: exclude_service_id,
          extra_routes: extra_routes
        )
      end

      def app_logs(service_id:, tail: nil)
        service = find_app_service(service_id)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        raise Valpo::ValidationError, "No active or ready release is available for logs" unless release&.container_name

        runtime_for.app_logs(container_name: release.container_name, tail: tail)
      end

      private

      attr_reader :config, :docker, :caddy, :health_checker, :port_resolver, :domain_verifier, :service_orchestrator, :sleeper

      def verify_service_domains(service, queue:, job_id:)
        domains = Valpo::Domain.where(service_id: service.id).exclude(status: "verified").order(:hostname).all
        if domains.empty?
          event(queue, job_id, "system", "No domain is configured; the release will remain private")
          return
        end

        domains.each do |domain|
          verify_domain_record(domain, queue: queue, job_id: job_id, activate_ready: false)
        rescue Valpo::ValidationError => e
          event(queue, job_id, "stderr", e.message)
        end
      end

      def verify_domain_record(domain, queue:, job_id:, activate_ready:)
        event(queue, job_id, "system", "Verifying #{domain.hostname}")
        verify_challenge!(hostname: domain.hostname, token: domain.verification_token, queue: queue, job_id: job_id)
        domain.update(status: "verified", verification_error: nil, verified_at: Time.now.utc)
        active_platform = Valpo::Domains::Configuration.active
        if activate_ready
          activate_ready_release(domain.service, queue: queue, job_id: job_id)
        else
          apply_caddy_config(queue: queue, job_id: job_id)
        end
        if domain.kind == "generated" && active_platform&.id == domain.platform_domain_id
          Valpo::Domains::Configuration.retire_stale_generated!(domain.service, keep: domain)
          apply_caddy_config(queue: queue, job_id: job_id)
        end
        domain.refresh
      rescue => e
        domain&.update(status: "failed", verification_error: e.message, verified_at: nil)
        safely_apply_caddy_config(queue: queue, job_id: job_id)
        raise
      end

      def verify_challenge!(hostname:, token:, queue:, job_id:)
        route = {hostname: hostname, kind: "verification", token: token}
        apply_caddy_config(queue: queue, job_id: job_id, extra_routes: [route])
        domain_verifier.verify!(hostname: hostname, token: token)
      end

      def activate_ready_release(service, queue:, job_id:)
        release = Valpo::Release.ready_for_service(service.id)
        unless release&.route_target
          apply_caddy_config(queue: queue, job_id: job_id)
          return nil
        end

        old_active = Valpo::Release.active_for_service(service.id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: release)
        release.activate!
        service.update(status: "running")
        retire_container(old_active, runtime_for(queue: queue, job_id: job_id))
        event(queue, job_id, "system", "Activated release #{release.version} on #{service.name}")
        release.refresh
      end

      def verified_domain?(service)
        Valpo::Domain.where(service_id: service.id, status: "verified").count.positive?
      end

      def ensure_verified_domain!(service)
        return unless service.web?
        return if verified_domain?(service)

        raise Valpo::ValidationError, "A verified domain is required to activate a web release"
      end

      def safely_apply_caddy_config(queue:, job_id:)
        apply_caddy_config(queue: queue, job_id: job_id)
      rescue => e
        event(queue, job_id, "stderr", "Could not restore Caddy config: #{e.message}")
      end

      def deploy_image(service_id:, image:, source_type:, source_ref:, build_target_id:, internal_port:, healthcheck_path:, pull:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        service = find_app_service(service_id)
        app_config = Valpo::AppServiceConfig[service.id]
        configured_port = internal_port || app_config&.internal_port

        old_active = Valpo::Release.active_for_service(service.id)
        old_ready = Valpo::Release.ready_for_service(service.id)
        release = nil
        container_name = nil

        service.update(status: "provisioning")
        if pull
          event(queue, job_id, "system", "Pulling #{image}")
          runtime.pull_image(image)
        else
          event(queue, job_id, "system", "Deploying built image #{image}")
        end
        image_metadata = runtime.inspect_image_metadata(image)
        port = port_resolver.resolve(
          service: service,
          explicit_port: configured_port,
          source_type: source_type,
          image_metadata: image_metadata
        )
        digest = image_metadata.digest
        release = Valpo::Release.create(
          service_id: service.id,
          build_target_id: build_target_id || app_config&.build_target_id,
          source_type: source_type,
          source_ref: source_ref,
          artifact_ref: digest || image,
          image_digest: digest,
          internal_port: port,
          healthcheck_path: blank_to_nil(healthcheck_path) || app_config&.healthcheck_path
        )

        container_name = runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        verify_service_domains(service, queue: queue, job_id: job_id) if service.web? && !verified_domain?(service)
        if service.web? && !verified_domain?(service)
          release.ready!
          service.update(status: old_active ? "running" : "ready")
          retire_container(old_ready, runtime)
          event(queue, job_id, "system", "Release is ready but remains private until a domain is verified")
        else
          apply_caddy_config(queue: queue, job_id: job_id, override_release: release)
          release.activate!
          service.update(status: "running")
          retire_container(old_active, runtime)
          retire_container(old_ready, runtime)
        end
        release.refresh
      rescue
        release&.fail!
        runtime&.cleanup_container(container_name)
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

        event(queue, job_id, "system", "Waiting for health check on #{release.route_target}")
        health_checker.wait(route_target: release.route_target, path: release.healthcheck_path, timeout: config.healthcheck_timeout)
      end

      def repair_active_containers(runtime, queue:, job_id:)
        Valpo::Service.where(kind: Valpo::Service::APP_KINDS).exclude(status: "stopped").order(:name).each do |service|
          release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
          next unless release

          repair_release_container(service, release, runtime, queue: queue, job_id: job_id)
        end
      end

      def repair_release_container(service, release, runtime, queue:, job_id:)
        desired_status = (release.status == "ready") ? "ready" : "running"
        inspection = runtime.inspect_container(release.container_name) if release.container_name
        if inspection && (release.route_target || !service.web?)
          runtime.update_restart_policy(release.container_name)
          unless inspection.dig("State", "Running")
            event(queue, job_id, "system", "Starting #{release.container_name}")
            runtime.start_container(release.container_name)
            wait_for_release(release, queue: queue, job_id: job_id)
          end
          service.update(status: desired_status) unless service.status == desired_status
          return
        end

        if inspection
          runtime.stop_container(release.container_name, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end
        event(queue, job_id, "system", "Recreating runtime for #{service.name}")
        runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        service.update(status: desired_status)
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
