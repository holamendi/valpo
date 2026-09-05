# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Services
    class Runtime
      MANAGED_LABEL = "valpo.managed"
      OWNED_LABEL = "valpo.owned"
      SERVICE_ID_LABEL = "valpo.service_id"
      SERVICE_TYPE_LABEL = "valpo.service_type"
      VOLUME_PATH_LABEL = "valpo.volume_path"
      READY_RETRY_INTERVAL = 0.25

      include Valpo::Deployments::CommandOutput

      def initialize(
        config:,
        docker:,
        queue: nil,
        job_id: nil,
        sleeper: Kernel,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      )
        @config = config
        @docker = docker
        @queue = queue
        @job_id = job_id
        @sleeper = sleeper
        @clock = clock
      end

      def restart_service_container(service)
        verified_existing_volume = validate_service_container_volume!(service)
        stop_container(Registry.managed_config(service).container_name, ignore_missing: true)
        start_service_container(service, allow_unlabeled_existing_volume: verified_existing_volume)
      end

      def validate_service_container_volume!(service)
        validate_postgres_container_volume!(service)
      end

      def start_service_container(service, allow_unlabeled_existing_volume: false)
        started = false
        managed = Registry.managed_config(service)
        ensure_network
        prepare_volume(service, allow_unlabeled_existing_volume:)
        event("system", "Starting #{managed.container_name}")
        result = docker.run_container(
          name: managed.container_name,
          image: managed.image,
          network: config.docker_network,
          labels: labels_for(service),
          env: Registry.container_environment(service),
          ports: {},
          volumes: {managed.volume_name => Registry.volume_path(service)},
          restart_policy: "unless-stopped",
          log_driver: "local",
          log_options: {
            "max-file" => config.container_log_max_files,
            "max-size" => config.container_log_max_size
          },
          command_args: Registry.command(service)
        )
        emit_command_output(result)
        raise_command_error("Docker run failed", result) unless result.fetch(:success)

        started = true
        wait_until_ready(service)
        managed.container_name
      rescue
        cleanup_started_container(managed.container_name) if started
        raise
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

      def remove_volume(volume_name, ignore_missing:)
        return if volume_name.nil? || volume_name.empty?

        result = docker.execute(docker.volume_rm_command(volume_name, force: true))
        emit_command_output(result)
        raise_command_error("Docker volume rm failed", result) if command_failed?(result, ignore_missing:)
      end

      def logs(container_name:, tail: nil)
        result = docker.execute(docker.logs_command(container_name, tail:))
        raise_command_error("Docker logs failed", result) unless result.fetch(:success)

        {stdout: result.fetch(:stdout), stderr: result.fetch(:stderr)}
      end

      def wait_until_ready(service)
        event("system", "Waiting for #{service.name} readiness")
        deadline = clock.call + config.healthcheck_timeout
        last_result = nil

        loop do
          last_result = docker.execute(docker.exec_command(Registry.managed_config(service).container_name, *Registry.readiness_command(service)))
          return true if last_result.fetch(:success)

          break if clock.call >= deadline

          sleeper.sleep(READY_RETRY_INTERVAL)
        end

        raise_command_error("#{service.kind} readiness failed", last_result)
      end

      private

      attr_reader :config, :docker, :queue, :job_id, :sleeper, :clock

      def cleanup_started_container(container_name)
        stop_container(container_name, ignore_missing: true)
      rescue => e
        event("stderr", "Cleanup failed for #{container_name}: #{e.message}")
      end

      def labels_for(service)
        {
          MANAGED_LABEL => "true",
          OWNED_LABEL => "true",
          SERVICE_ID_LABEL => service.id,
          SERVICE_TYPE_LABEL => service.kind,
          "valpo.project_id" => service.project_id
        }
      end

      def ensure_network
        result = docker.execute(docker.network_create_command(config.docker_network, labels: {OWNED_LABEL => "true"}))
        return if result.fetch(:success)
        if result.fetch(:stderr).include?("already exists")
          return if owned_network?

          raise Valpo::ValidationError,
            "Docker network #{config.docker_network} exists without #{OWNED_LABEL}=true"
        end
        emit_command_output(result)
        raise_command_error("Docker network create failed", result)
      end

      def owned_network?
        result = docker.execute(docker.network_inspect_command(config.docker_network))
        return false unless result.fetch(:success)

        JSON.parse(result.fetch(:stdout)).first&.dig("Labels", OWNED_LABEL) == "true"
      rescue JSON::ParserError
        false
      end

      def prepare_volume(service, allow_unlabeled_existing_volume: false)
        managed = Registry.managed_config(service)
        target = Registry.volume_path(service)
        inspection = inspect_volume(managed.volume_name)
        unless inspection
          create_volume(managed.volume_name, target:)
          return
        end

        return unless protected_postgres_layout?(service)
        return if inspection.dig("Labels", VOLUME_PATH_LABEL) == target
        return if allow_unlabeled_existing_volume

        raise_unsafe_postgres_volume!(service, managed.volume_name)
      end

      def create_volume(volume_name, target:)
        execute_docker(
          docker.volume_create_command(
            volume_name,
            labels: {OWNED_LABEL => "true", VOLUME_PATH_LABEL => target}
          ),
          failure_message: "Docker volume create failed"
        )
      end

      def inspect_volume(volume_name)
        result = docker.execute(docker.volume_inspect_command(volume_name))
        return nil if !result.fetch(:success) && missing_volume?(result)

        emit_command_output(result) unless result.fetch(:success)
        raise_command_error("Docker volume inspect failed", result) unless result.fetch(:success)

        JSON.parse(result.fetch(:stdout)).first
      rescue JSON::ParserError => e
        raise Valpo::ValidationError, "Docker volume inspect returned invalid JSON for #{volume_name}: #{e.message}"
      end

      def validate_postgres_container_volume!(service)
        return true unless protected_postgres_layout?(service)

        managed = Registry.managed_config(service)
        inspection = inspect_container(managed.container_name)
        return false unless inspection

        target = Registry.volume_path(service)
        named_mount = Array(inspection["Mounts"]).find do
          it["Type"] == "volume" && it["Name"] == managed.volume_name
        end
        return true if named_mount&.fetch("Destination", nil) == target

        raise_unsafe_postgres_volume!(service, managed.volume_name)
      end

      def protected_postgres_layout?(service)
        service.kind == "postgres" && %w[16 17].include?(Registry.managed_config(service).version)
      end

      def raise_unsafe_postgres_volume!(service, volume_name)
        version = Registry.managed_config(service).version
        raise Valpo::ValidationError,
          "Refusing to recreate PostgreSQL #{version} service #{service.name}: volume #{volume_name} " \
          "does not have a verified data-directory layout. Inspect and recover it using " \
          "docs/valpo-managed-services.md before retrying."
      end

      def execute_docker(command, failure_message:)
        execute_command(docker, command, failure_message:)
      end

      def missing_container?(result)
        stderr = result.fetch(:stderr).to_s.downcase
        stderr.include?("no such container") || stderr.include?("no such object")
      end

      def missing_volume?(result)
        stderr = result.fetch(:stderr).downcase
        stderr.include?("no such volume") || stderr.include?("no such object")
      end

      def command_failed?(result, ignore_missing:)
        return false if result.fetch(:success)
        return false if ignore_missing && (missing_container?(result) || missing_volume?(result))

        true
      end
    end
  end
end
