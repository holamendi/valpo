# frozen_string_literal: true

module Valpo
  module Services
    class ManagedLifecycle
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        dependency_manager: nil,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @dependency_manager = dependency_manager
        @sleeper = sleeper
      end

      def provision_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        runtime = runtime_for(queue:, job_id:)
        managed = Registry.managed_config(service)
        managed.update(Registry.runtime_attributes(service))
        service.update(status: "provisioning")
        event(queue, job_id, "system", "Provisioning #{service.name}")
        runtime.start_service_container(service.refresh)
        service.update(status: "running")
        service.refresh
      rescue
        service&.update(status: "failed") unless service&.status == "deleting"
        raise
      end

      def restart_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        runtime = runtime_for(queue:, job_id:)
        service.update(status: "restarting")
        event(queue, job_id, "system", "Restarting #{service.name}")
        runtime.restart_service_container(service)
        service.update(status: "running")
        service.refresh
      rescue
        service&.update(status: "failed") unless service&.status == "deleting"
        raise
      end

      def stop_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        managed = Registry.managed_config(service)
        runtime_for(queue:, job_id:).stop_container(managed.container_name, ignore_missing: true)
        service.update(status: "stopped")
      end

      def delete_service(service_id:, force:, queue:, job_id:)
        raise Valpo::ValidationError, "force=true is required to delete a service" unless force

        service = find_managed_service(service_id)
        managed = Registry.managed_config(service)
        runtime = runtime_for(queue:, job_id:)
        dependencies = Valpo::ServiceDependency.where(dependency_service_id: service.id).all
        original_statuses = dependencies.to_h { [it.id, it.status] }
        service.update(status: "deleting")
        dependencies.each { it.update(status: "deleting") }
        dependencies.each do
          app = Valpo::Service[it.service_id]
          dependency_manager.restart_app_if_running(app, queue:, job_id:) if app
        end
        runtime.stop_container(managed.container_name, ignore_missing: true)
        runtime.remove_volume(managed.volume_name, ignore_missing: true)
        dependencies.each(&:destroy)
        service.destroy
        true
      rescue
        Valpo::Service.where(id: service&.id).update(status: "failed") if service
        original_statuses&.each do |id, status|
          Valpo::ServiceDependency.where(id:).update(status:)
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

      attr_reader :config, :docker, :sleeper

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
            runtime.start_container(managed.container_name)
            runtime.wait_until_ready(service)
          end
        else
          event(queue, job_id, "system", "Recreating service runtime for #{service.name}")
          runtime.start_service_container(service)
        end
        service.update(status: "running")
      rescue
        service.update(status: "failed")
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
        Runtime.new(config:, docker:, queue:, job_id:, sleeper:)
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end
    end
  end
end
