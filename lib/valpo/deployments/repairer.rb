# frozen_string_literal: true

module Valpo
  module Deployments
    class Repairer
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        health_checker: HealthChecker.new,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @health_checker = health_checker
        @sleeper = sleeper
      end

      def repair_services(queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        Valpo::Service.where(kind: Valpo::Service::APP_KINDS)
          .exclude(status: "stopped")
          .order(:name)
          .each { repair_service(it, runtime, queue:, job_id:) }
        true
      end

      private

      attr_reader :config, :docker, :health_checker, :sleeper

      def repair_service(service, runtime, queue:, job_id:)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        return unless release

        desired_status = (release.status == "ready") ? "ready" : "running"
        inspection = runtime.inspect_container(release.container_name) if release.container_name
        if inspection && (release.route_target || !service.web?)
          runtime.update_restart_policy(release.container_name)
          unless inspection.dig("State", "Running")
            event(queue, job_id, "Starting #{release.container_name}")
            runtime.start_container(release.container_name)
            wait_for_release(release, queue:, job_id:)
          end
          service.update(status: desired_status) unless service.status == desired_status
          return
        end

        if inspection
          runtime.stop_container(release.container_name, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end
        event(queue, job_id, "Recreating runtime for #{service.name}")
        runtime.start_release_container(release)
        wait_for_release(release, queue:, job_id:)
        service.update(status: desired_status)
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

      def runtime_for(queue:, job_id:)
        Runtime.new(config:, docker:, queue:, job_id:, sleeper:)
      end

      def event(queue, job_id, message)
        queue.event(job_id, "system", message)
      end
    end
  end
end
