# frozen_string_literal: true

require "json"
require "securerandom"

module Valpo
  module Deployments
    class Runtime
      MANAGED_LABEL = "valpo.managed"
      PROJECT_LABEL = "valpo.project_id"
      RELEASE_LABEL = "valpo.release_id"
      SERVICE_LABEL = "valpo.service_id"

      include CommandOutput

      def initialize(config:, docker:, queue: nil, job_id: nil, sleeper: Kernel)
        @config = config
        @docker = docker
        @queue = queue
        @job_id = job_id
        @sleeper = sleeper
      end

      def pull_image(image)
        execute_docker(docker.pull_command(image), failure_message: "Docker command failed")
      end

      def inspect_image_metadata(image)
        result = execute_docker(docker.image_inspect_command(image), failure_message: "Docker command failed")
        parsed = JSON.parse(result.fetch(:stdout))
        first = parsed.first || {}
        repo_digest = Array(first["RepoDigests"]).first
        exposed_ports = first.dig("Config", "ExposedPorts").to_h.keys.filter_map do
          port, protocol = it.to_s.split("/", 2)
          Integer(port, exception: false) if protocol == "tcp"
        end.uniq.sort
        Valpo::Deployments::ImageMetadata.new(
          digest: repo_digest || first["Id"],
          exposed_tcp_ports: exposed_ports
        )
      rescue JSON::ParserError => e
        raise Valpo::ValidationError, "Docker image inspect returned invalid JSON: #{e.message}"
      end

      def inspect_image_digest(image)
        inspect_image_metadata(image).digest
      end

      def start_release_container(release)
        ensure_network
        host_port = allocate_port if release.internal_port
        route_target = "127.0.0.1:#{host_port}" if host_port
        container_name = container_name_for(release)
        image = release.artifact_ref || release.source_ref
        service = Valpo::Service[release.service_id]
        app_config = Valpo::AppServiceConfig[release.service_id]

        event("system", ["Starting #{container_name}", ("on #{route_target}" if route_target)].compact.join(" "))
        environment = Valpo::Services::Environment.raw_for_service(service.id)
        environment = environment.merge("PORT" => release.internal_port.to_s) if service.web?
        command = app_config&.command || []
        entrypoint = "/cnb/lifecycle/launcher" if release.build_strategy == "buildpack" && !command.empty?
        result = docker.execute(docker.run_command(
          name: container_name,
          image:,
          network: config.docker_network,
          labels: {
            MANAGED_LABEL => "true",
            PROJECT_LABEL => service.project_id,
            RELEASE_LABEL => release.id,
            SERVICE_LABEL => service.id
          },
          env: environment,
          ports: host_port ? {"127.0.0.1:#{host_port}" => release.internal_port} : {},
          restart_policy: "unless-stopped",
          entrypoint:,
          command_args: command
        ))
        emit_command_output(result)
        raise_command_error("Docker run failed", result) unless result.fetch(:success)

        release.update(container_name:, route_target:)
        container_name
      end

      def inspect_container(container_name)
        result = docker.execute(docker.container_inspect_command(container_name))
        return nil if !result.fetch(:success) && missing_container?(result)

        emit_command_output(result) unless result.fetch(:success)
        raise_command_error("Docker inspect failed", result) unless result.fetch(:success)

        JSON.parse(result.fetch(:stdout)).first
      rescue JSON::ParserError => e
        raise Valpo::ValidationError, "Docker inspect returned invalid JSON for #{container_name}: #{e.message}"
      end

      def update_restart_policy(container_name)
        execute_docker(
          docker.update_restart_policy_command(container_name, "unless-stopped"),
          failure_message: "Docker update failed"
        )
      end

      def start_container(container_name)
        execute_docker(docker.start_command(container_name), failure_message: "Docker command failed")
      end

      def stop_container(container_name, ignore_missing:)
        return if container_name.nil? || container_name.empty?

        event("system", "Stopping #{container_name}")
        stop_result = docker.execute(docker.stop_command(container_name))
        emit_command_output(stop_result)
        raise_command_error("Docker stop failed", stop_result) if command_failed?(stop_result, ignore_missing:)

        rm_result = docker.execute(docker.rm_command(container_name, force: true))
        emit_command_output(rm_result)
        raise_command_error("Docker rm failed", rm_result) if command_failed?(rm_result, ignore_missing:)

        sleeper.sleep(config.deploy_drain_delay) if config.deploy_drain_delay.positive?
      end

      def cleanup_container(container_name)
        stop_container(container_name, ignore_missing: true) if container_name
      rescue => e
        event("stderr", "Cleanup failed for #{container_name}: #{e.message}")
      end

      def app_logs(container_name:, tail: nil)
        result = docker.execute(docker.logs_command(container_name, tail:))
        raise_command_error("Docker logs failed", result) unless result.fetch(:success)

        {stdout: result.fetch(:stdout), stderr: result.fetch(:stderr)}
      end

      private

      attr_reader :config, :docker, :queue, :job_id, :sleeper

      def ensure_network
        result = docker.execute(docker.network_create_command(config.docker_network))
        return if result.fetch(:success)
        return if result.fetch(:stderr).include?("already exists")

        emit_command_output(result)
        raise_command_error("Docker network create failed", result)
      end

      def execute_docker(command, failure_message:)
        execute_command(docker, command, failure_message:)
      end

      def missing_container?(result)
        stderr = result.fetch(:stderr)
        stderr.include?("No such container") || stderr.include?("No such object")
      end

      def command_failed?(result, ignore_missing:)
        !result.fetch(:success) && !(ignore_missing && missing_container?(result))
      end

      def allocate_port
        used_ports = Valpo::Release.where(status: %w[pending ready active])
          .exclude(route_target: nil)
          .map { it.route_target.to_s.split(":").last.to_i }
        (config.app_port_start..config.app_port_end).each do
          return it unless used_ports.include?(it)
        end

        raise Valpo::ValidationError, "No app ports are available"
      end

      def container_name_for(release)
        service = Valpo::Service[release.service_id]
        project = service.project
        "valpo-#{project.name}-#{service.name}-r#{release.version}-#{release.id.split("_").last[0, 8]}-#{SecureRandom.hex(4)}"
      end
    end
  end
end
