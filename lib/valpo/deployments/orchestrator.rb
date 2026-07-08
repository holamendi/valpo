# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "time"
require "valpo"
require "valpo/caddy/client"
require "valpo/docker/client"
require "valpo/models/domain"
require "valpo/models/project"
require "valpo/models/release"

module Valpo
  module Deployments
    class HealthChecker
      RETRY_INTERVAL = 0.25

      def wait(route_target:, path:, timeout:)
        deadline = Time.now + timeout
        last_error = nil

        loop do
          begin
            return true if healthy?(route_target: route_target, path: path)
          rescue StandardError => e
            last_error = e
          end

          break if Time.now >= deadline

          sleep RETRY_INTERVAL
        end

        detail = last_error ? ": #{last_error.message}" : ""
        raise Valpo::ValidationError, "Health check failed for #{route_target}#{detail}"
      end

      private

      def healthy?(route_target:, path:)
        host, port = route_target.split(":", 2)
        port = Integer(port)

        if path && !path.empty?
          response = Net::HTTP.start(host, port, open_timeout: 1, read_timeout: 1) do |http|
            http.get(path)
          end
          response.code.to_i.between?(200, 399)
        else
          socket = TCPSocket.new(host, port)
          socket.close
          true
        end
      end
    end

    class Orchestrator
      MANAGED_LABEL = "valpo.managed"
      PROJECT_LABEL = "valpo.project_id"
      RELEASE_LABEL = "valpo.release_id"
      SERVICE_LABEL = "valpo.service"

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
        project = find_project(project_id)
        old_active = Valpo::Release.active_for_project(project.id)
        release = nil
        container_name = nil

        project.update(status: "deploying")
        event(queue, job_id, "system", "Pulling #{image}")
        run_docker(docker.pull_command(image), queue: queue, job_id: job_id)
        digest = inspect_image_digest(image, queue: queue, job_id: job_id)

        release = Valpo::Release.create(
          project_id: project.id,
          source_type: "registry",
          source_ref: image,
          artifact_ref: digest || image,
          image_digest: digest,
          internal_port: internal_port,
          healthcheck_path: blank_to_nil(healthcheck_path)
        )

        container_name = start_release_container(release, queue: queue, job_id: job_id)
        wait_for_release(release, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: release)
        release.activate!
        project.update(status: "running")
        if old_active&.container_name
          stop_container(old_active.container_name, queue: queue, job_id: job_id, ignore_missing: true)
          old_active.update(container_name: nil, route_target: nil)
        end

        release.refresh
      rescue StandardError
        release&.fail!
        cleanup_container(container_name, queue: queue, job_id: job_id)
        project&.update(status: old_active ? "running" : "failed")
        raise
      end

      def rollback_project(project_id:, queue:, job_id:)
        project = find_project(project_id)
        current = Valpo::Release.active_for_project(project.id)
        target = Valpo::Release.previous_deployable_for_project(project.id, excluding_release_id: current&.id)
        raise Valpo::ValidationError, "No previous release is available for rollback" unless target

        previous_container = target.container_name
        previous_route_target = target.route_target
        new_container = nil

        project.update(status: "deploying")
        new_container = start_release_container(target, queue: queue, job_id: job_id)
        wait_for_release(target, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: target)
        target.activate!
        project.update(status: "running")
        if current&.container_name
          stop_container(current.container_name, queue: queue, job_id: job_id, ignore_missing: true)
          current.update(container_name: nil, route_target: nil)
        end

        target.refresh
      rescue StandardError
        cleanup_container(new_container, queue: queue, job_id: job_id)
        target&.update(container_name: previous_container, route_target: previous_route_target)
        project&.update(status: current ? "running" : "failed")
        raise
      end

      def stop_project(project_id:, queue:, job_id:)
        project = find_project(project_id)
        active = Valpo::Release.active_for_project(project.id)
        if active&.container_name
          stop_container(active.container_name, queue: queue, job_id: job_id, ignore_missing: true)
          active.update(container_name: nil, route_target: nil)
        end
        project.update(status: "stopped")
        apply_caddy_config(queue: queue, job_id: job_id)
        project
      end

      def restart_project(project_id:, queue:, job_id:)
        project = find_project(project_id)
        active = Valpo::Release.active_for_project(project.id)
        raise Valpo::ValidationError, "No active release is available to restart" unless active

        old_container = active.container_name
        previous_route_target = active.route_target
        new_container = nil

        project.update(status: "deploying")
        new_container = start_release_container(active, queue: queue, job_id: job_id)
        wait_for_release(active, queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id, override_release: active)
        project.update(status: "running")
        stop_container(old_container, queue: queue, job_id: job_id, ignore_missing: true) if old_container && old_container != new_container

        active.refresh
      rescue StandardError
        cleanup_container(new_container, queue: queue, job_id: job_id)
        active&.update(container_name: old_container, route_target: previous_route_target)
        project&.update(status: active ? "running" : "failed")
        raise
      end

      def delete_project(project_id:, queue:, job_id:)
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
          stop_container(container_name, queue: queue, job_id: job_id, ignore_missing: true)
        end

        project.destroy
        event(queue, job_id, "system", "Deleted #{project_name}")
        true
      end

      def repair_system(queue:, job_id:)
        event(queue, job_id, "system", "Repairing system state")
        repair_active_containers(queue: queue, job_id: job_id)
        apply_caddy_config(queue: queue, job_id: job_id)
        true
      end

      def apply_caddy_config(queue:, job_id:, override_release: nil, exclude_project_id: nil)
        routes, route_targets = caddy_routes(override_release: override_release, exclude_project_id: exclude_project_id)
        event(queue, job_id, "system", "Applying Caddy config")
        caddy.write_config(routes)
        result = caddy.execute(caddy.reload_command)
        emit_command_output(result, queue: queue, job_id: job_id)
        raise_command_error("Caddy reload failed", result) unless result.fetch(:success)

        route_targets.each do |domain_id, route_target|
          Valpo::Domain.where(id: domain_id).update(route_target: route_target)
        end
      end

      def app_logs(project_id:, tail: nil)
        project = find_project(project_id)
        active = Valpo::Release.active_for_project(project.id)
        raise Valpo::ValidationError, "No active release is available for logs" unless active&.container_name

        result = docker.execute(docker.logs_command(active.container_name, tail: tail))
        raise_command_error("Docker logs failed", result) unless result.fetch(:success)

        { stdout: result.fetch(:stdout), stderr: result.fetch(:stderr) }
      end

      private

      attr_reader :config, :docker, :caddy, :health_checker, :sleeper

      def find_project(project_id)
        project = Valpo::Project[project_id]
        raise Valpo::ValidationError, "Project not found: #{project_id}" unless project
        raise Valpo::ValidationError, "Only container projects can be deployed" unless project.type == "container"

        project
      end

      def start_release_container(release, queue:, job_id:)
        ensure_network(queue: queue, job_id: job_id)
        host_port = allocate_port
        route_target = "127.0.0.1:#{host_port}"
        container_name = container_name_for(release)
        image = release.artifact_ref || release.source_ref

        event(queue, job_id, "system", "Starting #{container_name} on #{route_target}")
        result = docker.execute(docker.run_command(
          name: container_name,
          image: image,
          network: config.docker_network,
          labels: {
            MANAGED_LABEL => "true",
            PROJECT_LABEL => release.project_id,
            RELEASE_LABEL => release.id,
            SERVICE_LABEL => "web"
          },
          ports: { "127.0.0.1:#{host_port}" => release.internal_port },
          restart_policy: "unless-stopped"
        ))
        emit_command_output(result, queue: queue, job_id: job_id)
        raise_command_error("Docker run failed", result) unless result.fetch(:success)

        release.update(container_name: container_name, route_target: route_target)
        container_name
      end

      def wait_for_release(release, queue:, job_id:)
        event(queue, job_id, "system", "Waiting for health check on #{release.route_target}")
        health_checker.wait(
          route_target: release.route_target,
          path: release.healthcheck_path,
          timeout: config.healthcheck_timeout
        )
      end

      def ensure_network(queue:, job_id:)
        result = docker.execute(docker.network_create_command(config.docker_network))
        return if result.fetch(:success)
        return if result.fetch(:stderr).include?("already exists")

        emit_command_output(result, queue: queue, job_id: job_id)
        raise_command_error("Docker network create failed", result)
      end

      def inspect_image_digest(image, queue:, job_id:)
        result = run_docker(docker.image_inspect_command(image), queue: queue, job_id: job_id)
        parsed = JSON.parse(result.fetch(:stdout))
        first = parsed.first || {}
        repo_digest = Array(first["RepoDigests"]).first
        repo_digest || first["Id"]
      rescue JSON::ParserError
        nil
      end

      def caddy_routes(override_release:, exclude_project_id: nil)
        routes = []
        route_targets = {}
        exclude_project_id = exclude_project_id&.to_s

        Valpo::Domain.order(:hostname).each do |domain|
          if exclude_project_id == domain.project_id.to_s
            route_targets[domain.id] = nil
            next
          end

          project = Valpo::Project[domain.project_id]
          release = override_release&.project_id == domain.project_id ? override_release : Valpo::Release.active_for_project(domain.project_id)

          if project.nil? || project.status == "stopped" || release&.route_target.nil?
            route_targets[domain.id] = nil
            next
          end

          routes << { hostname: domain.hostname, kind: "container", upstream: release.route_target }
          route_targets[domain.id] = release.route_target
        end

        [routes, route_targets]
      end

      def repair_active_containers(queue:, job_id:)
        Valpo::Project.where(type: "container").exclude(status: "stopped").order(:name).each do |project|
          release = Valpo::Release.active_for_project(project.id)
          next unless release

          repair_release_container(project, release, queue: queue, job_id: job_id)
        end
      end

      def repair_release_container(project, release, queue:, job_id:)
        inspection = inspect_container(release.container_name, queue: queue, job_id: job_id) if release.container_name

        if inspection && release.route_target
          update_restart_policy(release.container_name, queue: queue, job_id: job_id)
          unless inspection.dig("State", "Running")
            event(queue, job_id, "system", "Starting #{release.container_name}")
            run_docker(docker.start_command(release.container_name), queue: queue, job_id: job_id)
            wait_for_release(release, queue: queue, job_id: job_id)
          end
          project.update(status: "running") unless project.status == "running"
          return
        end

        if inspection
          event(queue, job_id, "system", "Recreating unroutable runtime for #{project.name}")
          stop_container(release.container_name, queue: queue, job_id: job_id, ignore_missing: true)
          release.update(container_name: nil, route_target: nil)
        end

        event(queue, job_id, "system", "Recreating runtime for #{project.name}")
        start_release_container(release, queue: queue, job_id: job_id)
        wait_for_release(release, queue: queue, job_id: job_id)
        project.update(status: "running")
      end

      def inspect_container(container_name, queue:, job_id:)
        result = docker.execute(docker.container_inspect_command(container_name))
        return nil if !result.fetch(:success) && missing_container?(result)

        emit_command_output(result, queue: queue, job_id: job_id) unless result.fetch(:success)
        raise_command_error("Docker inspect failed", result) unless result.fetch(:success)

        JSON.parse(result.fetch(:stdout)).first
      rescue JSON::ParserError => e
        raise Valpo::ValidationError, "Docker inspect returned invalid JSON for #{container_name}: #{e.message}"
      end

      def update_restart_policy(container_name, queue:, job_id:)
        result = docker.execute(docker.update_restart_policy_command(container_name, "unless-stopped"))
        emit_command_output(result, queue: queue, job_id: job_id)
        raise_command_error("Docker update failed", result) unless result.fetch(:success)
      end

      def run_docker(command, queue:, job_id:)
        result = docker.execute(command)
        emit_command_output(result, queue: queue, job_id: job_id)
        raise_command_error("Docker command failed", result) unless result.fetch(:success)

        result
      end

      def stop_container(container_name, queue:, job_id:, ignore_missing:)
        return if container_name.nil? || container_name.empty?

        event(queue, job_id, "system", "Stopping #{container_name}")
        stop_result = docker.execute(docker.stop_command(container_name))
        emit_command_output(stop_result, queue: queue, job_id: job_id)
        raise_command_error("Docker stop failed", stop_result) unless stop_result.fetch(:success) || (ignore_missing && missing_container?(stop_result))

        rm_result = docker.execute(docker.rm_command(container_name, force: true))
        emit_command_output(rm_result, queue: queue, job_id: job_id)
        raise_command_error("Docker rm failed", rm_result) unless rm_result.fetch(:success) || (ignore_missing && missing_container?(rm_result))

        sleeper.sleep(config.deploy_drain_delay) if config.deploy_drain_delay.positive?
      end

      def cleanup_container(container_name, queue:, job_id:)
        stop_container(container_name, queue: queue, job_id: job_id, ignore_missing: true) if container_name
      rescue StandardError => e
        event(queue, job_id, "stderr", "Cleanup failed for #{container_name}: #{e.message}")
      end

      def missing_container?(result)
        stderr = result.fetch(:stderr)
        stderr.include?("No such container") || stderr.include?("No such object")
      end

      def emit_command_output(result, queue:, job_id:)
        stdout = result.fetch(:stdout).to_s.strip
        stderr = result.fetch(:stderr).to_s.strip
        event(queue, job_id, "stdout", stdout) unless stdout.empty?
        event(queue, job_id, "stderr", stderr) unless stderr.empty?
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end

      def raise_command_error(prefix, result)
        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "#{prefix}: #{detail}"
      end

      def allocate_port
        used_ports = Valpo::Release.where(status: %w[pending active])
                                   .exclude(route_target: nil)
                                   .map { |release| release.route_target.to_s.split(":").last.to_i }
        (config.app_port_start..config.app_port_end).each do |port|
          return port unless used_ports.include?(port)
        end

        raise Valpo::ValidationError, "No app ports are available"
      end

      def container_name_for(release)
        project = Valpo::Project[release.project_id]
        "valpo-#{project.name}-web-r#{release.version}-#{release.id[0, 8]}"
      end

      def blank_to_nil(value)
        value.nil? || value.to_s.empty? ? nil : value
      end
    end
  end
end
