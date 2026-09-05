# frozen_string_literal: true

module Valpo
  module Services
    class ManagedLifecycle
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        dependency_manager: nil,
        redis_host_requirements: RedisHostRequirements.new,
        sleeper: Kernel,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      )
        @config = config
        @docker = docker
        @dependency_manager = dependency_manager
        @redis_host_requirements = redis_host_requirements
        @sleeper = sleeper
        @clock = clock
      end

      def provision_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        runtime = runtime_for(queue:, job_id:)
        managed = Registry.managed_config(service)
        managed.update(Registry.runtime_attributes(service))
        service.transition_to!("provisioning")
        event(queue, job_id, "system", "Provisioning #{service.name}")
        start_service_container(runtime, service.refresh)
        service.transition_to!("running")
        service.refresh
      rescue
        service&.transition_to!("failed") unless service&.status == "deleting"
        raise
      end

      def restart_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        runtime = runtime_for(queue:, job_id:)
        service.transition_to!("restarting")
        event(queue, job_id, "system", "Restarting #{service.name}")
        validate_host_start!(service)
        runtime.restart_service_container(service)
        service.transition_to!("running")
        service.refresh
      rescue
        service&.transition_to!("failed") unless service&.status == "deleting"
        raise
      end

      def stop_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        managed = Registry.managed_config(service)
        runtime_for(queue:, job_id:).stop_container(managed.container_name, ignore_missing: true)
        service.transition_to!("stopped")
      end

      def delete_service(service_id:, force:, queue:, job_id:)
        raise Valpo::ValidationError, "force=true is required to delete a service" unless force

        service = find_managed_service(service_id)
        managed = Registry.managed_config(service)
        runtime = runtime_for(queue:, job_id:)
        dependencies = Valpo::ServiceDependency.where(dependency_service_id: service.id).all
        original_statuses = dependencies.to_h { [it.id, it.status] }
        original_service_status = service.status
        restarted_apps = []
        container_removed = false
        volume_deleted = false
        service.transition_to!("deleting")
        dependencies.each { it.transition_to!("deleting") }
        dependencies.each do
          app = Valpo::Service[it.service_id]
          next unless app

          restarted_apps << app if dependency_manager.restart_app_if_running(app, queue:, job_id:)
        end
        runtime.stop_container(managed.container_name, ignore_missing: true)
        container_removed = true
        runtime.remove_volume(managed.volume_name, ignore_missing: true)
        volume_deleted = true
        Valpo::Database.connection.transaction do
          dependencies.each(&:destroy)
          service.destroy
        end
        true
      rescue
        if volume_deleted
          service&.refresh&.transition_to!("failed")
        else
          restore_managed_runtime(
            service,
            runtime,
            original_status: original_service_status,
            container_removed:,
            queue:,
            job_id:
          )
          original_statuses&.each do |id, status|
            Valpo::ServiceDependency[id]&.transition_to!(status)
          end
          restore_restarted_apps(restarted_apps, queue:, job_id:)
        end
        raise
      end

      def repair_services(queue:, job_id:)
        runtime = runtime_for(queue:, job_id:)
        Valpo::Service.where(kind: Valpo::Service::MANAGED_KINDS)
          .exclude(status: %w[deleting stopped])
          .order(:name)
          .each { repair_service(it, runtime, queue:, job_id:) }
        true
      end

      def service_logs(service_id:, tail: nil)
        service = find_managed_service(service_id)
        container_name = Registry.managed_config(service).container_name
        raise Valpo::ValidationError, "Service has no container yet" unless container_name

        runtime_for.logs(container_name:, tail:)
      end

      private

      attr_reader :config, :docker, :redis_host_requirements, :sleeper, :clock

      def dependency_manager
        @dependency_manager ||= DependencyManager.new(config:, docker:, sleeper:)
      end

      def repair_service(service, runtime, queue:, job_id:)
        managed = ensure_runtime_attributes(service)
        inspection = runtime.inspect_container(managed.container_name)
        if inspection
          runtime.update_restart_policy(managed.container_name)
          unless inspection.dig("State", "Running")
            event(queue, job_id, "system", "Starting #{managed.container_name}")
            start_container(runtime, service, managed.container_name)
          end
          runtime.wait_until_ready(service)
        else
          event(queue, job_id, "system", "Recreating service runtime for #{service.name}")
          start_service_container(runtime, service)
        end
        service.transition_to!("running")
      rescue
        service.transition_to!("failed")
        raise
      end

      def ensure_runtime_attributes(service)
        managed = Registry.managed_config(service)
        if [managed.container_name, managed.volume_name, managed.internal_host, managed.internal_port].any?(&:nil?)
          managed.update(Registry.runtime_attributes(service))
        end
        managed.refresh
      end

      def find_managed_service(service_id)
        service = Valpo::Service[service_id] || raise(Valpo::ValidationError, "Service not found: #{service_id}")
        raise Valpo::ValidationError, "Operation requires a managed service" unless service.managed?

        service
      end

      def runtime_for(queue: nil, job_id: nil)
        Runtime.new(config:, docker:, queue:, job_id:, sleeper:, clock:)
      end

      def restore_restarted_apps(apps, queue:, job_id:)
        return unless apps

        apps.each do
          dependency_manager.restart_app_if_running(it.refresh, queue:, job_id:)
        rescue => e
          event(queue, job_id, "stderr", "Could not restore #{it.name} after failed deletion: #{e.message}")
        end
      end

      def restore_managed_runtime(service, runtime, original_status:, container_removed:, queue:, job_id:)
        return unless service && original_status

        if original_status == "running"
          if container_removed
            start_service_container(runtime, service)
          else
            inspection = runtime.inspect_container(Registry.managed_config(service).container_name)
            if inspection
              unless inspection.dig("State", "Running")
                start_container(runtime, service, Registry.managed_config(service).container_name)
              end
              runtime.wait_until_ready(service)
            else
              start_service_container(runtime, service)
            end
          end
        end
        service.refresh.transition_to!(original_status)
      rescue => e
        service.refresh.transition_to!("failed")
        event(queue, job_id, "stderr", "Could not restore #{service.name} after failed deletion: #{e.message}")
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end

      def start_service_container(runtime, service)
        validate_host_start!(service)
        runtime.start_service_container(service)
      end

      def start_container(runtime, service, container_name)
        validate_host_start!(service)
        runtime.start_container(container_name)
      end

      def validate_host_start!(service)
        redis_host_requirements.validate! if service.kind == "redis"
      end
    end
  end
end
