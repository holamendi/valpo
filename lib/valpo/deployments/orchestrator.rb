# frozen_string_literal: true

require "valpo"
require "valpo/caddy/client"
require "valpo/deployments/health_checker"
require "valpo/deployments/route_projector"
require "valpo/deployments/runtime"
require "valpo/docker/client"
require "valpo/models/project"
require "valpo/models/release"

module Valpo
  module Deployments
    class Orchestrator
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        caddy: Valpo::Caddy::Client.new(config_path: config.caddy_config_path, reload_config_path: config.caddy_reload_config_path),
        health_checker: HealthChecker.new,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @caddy = caddy
        @health_checker = health_checker
        @sleeper = sleeper
      end

      def deploy_registry_image(project_id:, image:, internal_port:, healthcheck_path:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        project = find_project(project_id)
        old_active = Valpo::Release.active_for_project(project.id)
        release = nil
        container_name = nil

        project.update(status: "deploying")
        event(queue, job_id, "system", "Pulling #{image}")
        runtime.pull_image(image)
        digest = runtime.inspect_image_digest(image)

        release = Valpo::Release.create(
          project_id: project.id,
          source_type: "registry",
          source_ref: image,
          artifact_ref: digest || image,
          image_digest: digest,
          internal_port: internal_port,
          healthcheck_path: blank_to_nil(healthcheck_path)
        )

        container_name = runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: release)
        release.activate!
        project.update(status: "running")
        if old_active&.container_name
          runtime.stop_container(old_active.container_name, ignore_missing: true)
          old_active.update(container_name: nil, route_target: nil)
        end

        release.refresh
      rescue
        release&.fail!
        runtime&.cleanup_container(container_name)
        project&.update(status: old_active ? "running" : "failed")
        raise
      end

      def rollback_project(project_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        project = find_project(project_id)
        current = Valpo::Release.active_for_project(project.id)
        target = Valpo::Release.previous_deployable_for_project(project.id, excluding_release_id: current&.id)
        raise Valpo::ValidationError, "No previous release is available for rollback" unless target

        previous_container = target.container_name
        previous_route_target = target.route_target
        new_container = nil

        project.update(status: "deploying")
        new_container = runtime.start_release_container(target)
        wait_for_release(target, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: target)
        target.activate!
        project.update(status: "running")
        if current&.container_name
          runtime.stop_container(current.container_name, ignore_missing: true)
          current.update(container_name: nil, route_target: nil)
        end

        target.refresh
      rescue
        runtime&.cleanup_container(new_container)
        target&.update(container_name: previous_container, route_target: previous_route_target)
        project&.update(status: current ? "running" : "failed")
        raise
      end

      def stop_project(project_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        project = find_project(project_id)
        active = Valpo::Release.active_for_project(project.id)
        if active&.container_name
          runtime.stop_container(active.container_name, ignore_missing: true)
          active.update(container_name: nil, route_target: nil)
        end
        project.update(status: "stopped")
        apply_caddy_config(queue: queue, job_id: job_id)
        project
      end

      def restart_project(project_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        project = find_project(project_id)
        active = Valpo::Release.active_for_project(project.id)
        raise Valpo::ValidationError, "No active release is available to restart" unless active

        old_container = active.container_name
        previous_route_target = active.route_target
        new_container = nil

        project.update(status: "deploying")
        new_container = runtime.start_release_container(active)
        wait_for_release(active, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: active)
        project.update(status: "running")
        runtime.stop_container(old_container, ignore_missing: true) if old_container && old_container != new_container

        active.refresh
      rescue
        runtime&.cleanup_container(new_container)
        active&.update(container_name: old_container, route_target: previous_route_target)
        project&.update(status: active ? "running" : "failed")
        raise
      end

      def delete_project(project_id:, queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        project = Valpo::Project[project_id]
        raise Valpo::ValidationError, "Project not found: #{project_id}" unless project

        project_name = project.name
        container_names = Valpo::Release.where(project_id: project.id)
          .exclude(container_name: nil)
          .select_map(:container_name)
          .uniq

        project.update(status: "deleting")
        event(queue, job_id, "system", "Deleting #{project_name}")
        apply_caddy_config(queue: queue, job_id: job_id, exclude_project_id: project.id)

        container_names.each do |container_name|
          runtime.stop_container(container_name, ignore_missing: true)
        end

        project.destroy
        event(queue, job_id, "system", "Deleted #{project_name}")
        true
      end

      def repair_system(queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        event(queue, job_id, "system", "Repairing system state")
        repair_active_containers(runtime, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id)
        true
      end

      def apply_caddy_config(queue:, job_id:, override_release: nil, exclude_project_id: nil)
        route_projector_for(queue: queue, job_id: job_id).apply(
          override_release: override_release,
          exclude_project_id: exclude_project_id
        )
      end

      def app_logs(project_id:, tail: nil)
        project = find_project(project_id)
        active = Valpo::Release.active_for_project(project.id)
        raise Valpo::ValidationError, "No active release is available for logs" unless active&.container_name

        runtime_for.app_logs(container_name: active.container_name, tail: tail)
      end

      private

      attr_reader :config, :docker, :caddy, :health_checker, :sleeper

      def find_project(project_id)
        project = Valpo::Project[project_id]
        raise Valpo::ValidationError, "Project not found: #{project_id}" unless project
        raise Valpo::ValidationError, "Only container projects can be deployed" unless project.type == "container"

        project
      end

      def wait_for_release(release, queue:, job_id:)
        event(queue, job_id, "system", "Waiting for health check on #{release.route_target}")
        health_checker.wait(
          route_target: release.route_target,
          path: release.healthcheck_path,
          timeout: config.healthcheck_timeout
        )
      end

      def repair_active_containers(runtime, queue:, job_id:)
        Valpo::Project.where(type: "container").exclude(status: "stopped").order(:name).each do |project|
          release = Valpo::Release.active_for_project(project.id)
          next unless release

          repair_release_container(project, release, runtime, queue: queue, job_id: job_id)
        end
      end

      def repair_release_container(project, release, runtime, queue:, job_id:)
        inspection = runtime.inspect_container(release.container_name) if release.container_name

        if inspection && release.route_target
          runtime.update_restart_policy(release.container_name)
          unless inspection.dig("State", "Running")
            event(queue, job_id, "system", "Starting #{release.container_name}")
            runtime.start_container(release.container_name)
            wait_for_release(release, queue: queue, job_id: job_id)
          end
          project.update(status: "running") unless project.status == "running"
          return
        end

        if inspection
          event(queue, job_id, "system", "Recreating unroutable runtime for #{project.name}")
          runtime.stop_container(release.container_name, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end

        event(queue, job_id, "system", "Recreating runtime for #{project.name}")
        runtime.start_release_container(release)
        wait_for_release(release, queue: queue, job_id: job_id)
        project.update(status: "running")
      end

      def runtime_for(queue: nil, job_id: nil)
        Runtime.new(config: config, docker: docker, queue: queue, job_id: job_id, sleeper: sleeper)
      end

      def route_projector_for(queue:, job_id:)
        RouteProjector.new(caddy: caddy, queue: queue, job_id: job_id)
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
