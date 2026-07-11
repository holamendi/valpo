# frozen_string_literal: true

require "json"

module Valpo
  module Services
    class Orchestrator
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        deployment_orchestrator: nil,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @deployment_orchestrator = deployment_orchestrator
        @sleeper = sleeper
      end

      def provision_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        runtime = runtime_for(queue: queue, job_id: job_id)
        managed = Catalog.managed_config(service)
        managed.update(Catalog.runtime_attributes(service))
        service.update(status: "provisioning")
        event(queue, job_id, "system", "Provisioning #{service.name}")
        runtime.start_service_container(service.refresh)
        service.update(status: "running")
        service.refresh
      rescue
        service&.update(status: "failed") unless service&.status == "deleting"
        raise
      end

      def bind_service(service_id:, dependency_service_id:, queue:, job_id:)
        app = find_app_service(service_id)
        managed = find_managed_service(dependency_service_id)
        validate_same_project!(app, managed)
        raise Valpo::ValidationError, "Managed service must be running before binding" unless managed.status == "running"

        env = Catalog.binding_env(managed)
        conflicts = Environment.conflicting_keys(service_id: app.id, dependency_service_id: managed.id, env: env)
        raise Valpo::ConflictError, "App service already has managed env keys: #{conflicts.sort.join(", ")}" unless conflicts.empty?

        dependency = upsert_dependency(app: app, managed: managed, env: env)
        event(queue, job_id, "system", "Bound #{managed.name} to #{app.name}")
        restart_app_if_running(app, queue: queue, job_id: job_id)
        dependency.refresh
      end

      def unbind_service(service_id:, dependency_service_id:, queue:, job_id:)
        app = find_app_service(service_id)
        managed = find_managed_service(dependency_service_id)
        dependency = Valpo::ServiceDependency.where(service_id: app.id, dependency_service_id: managed.id).first
        raise Valpo::ValidationError, "Service dependency not found" unless dependency

        dependency.update(status: "deleting")
        restart_app_if_running(app, queue: queue, job_id: job_id)
        dependency.destroy
        event(queue, job_id, "system", "Unbound #{managed.name} from #{app.name}")
        true
      rescue
        dependency&.update(status: "active") if dependency&.pk && Valpo::ServiceDependency[dependency.id]
        raise
      end

      def restart_service(service_id:, queue:, job_id:)
        service = find_managed_service(service_id)
        runtime = runtime_for(queue: queue, job_id: job_id)
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
        managed = Catalog.managed_config(service)
        runtime_for(queue: queue, job_id: job_id).stop_container(managed.container_name, ignore_missing: true)
        service.update(status: "stopped")
      end

      def delete_service(service_id:, force:, queue:, job_id:)
        raise Valpo::ValidationError, "force=true is required to delete a service" unless force

        service = find_managed_service(service_id)
        managed = Catalog.managed_config(service)
        runtime = runtime_for(queue: queue, job_id: job_id)
        dependencies = Valpo::ServiceDependency.where(dependency_service_id: service.id).all
        original_statuses = dependencies.to_h { |dependency| [dependency.id, dependency.status] }
        service.update(status: "deleting")
        dependencies.each { |dependency| dependency.update(status: "deleting") }
        dependencies.each do |dependency|
          app = Valpo::Service[dependency.service_id]
          restart_app_if_running(app, queue: queue, job_id: job_id) if app
        end
        runtime.stop_container(managed.container_name, ignore_missing: true)
        runtime.remove_volume(managed.volume_name, ignore_missing: true)
        dependencies.each(&:destroy)
        service.destroy
        true
      rescue
        Valpo::Service.where(id: service&.id).update(status: "failed") if service
        original_statuses&.each do |id, status|
          Valpo::ServiceDependency.where(id: id).update(status: status)
        end
        raise
      end

      def repair_services(queue:, job_id:)
        runtime = runtime_for(queue: queue, job_id: job_id)
        Valpo::Service.where(kind: Valpo::Service::MANAGED_KINDS).exclude(status: %w[deleting stopped]).order(:name).each do |service|
          repair_service(service, runtime, queue: queue, job_id: job_id)
        end
        true
      end

      def service_logs(service_id:, tail: nil)
        service = find_managed_service(service_id)
        container_name = Catalog.managed_config(service).container_name
        raise Valpo::ValidationError, "Service has no container yet" unless container_name

        runtime_for.logs(container_name: container_name, tail: tail)
      end

      private

      attr_reader :config, :docker, :deployment_orchestrator, :sleeper

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
        managed = Catalog.managed_config(service)
        if [managed.container_name, managed.volume_name, managed.internal_host, managed.internal_port].any?(&:nil?)
          managed.update(Catalog.runtime_attributes(service))
        end
        managed.refresh
      end

      def upsert_dependency(app:, managed:, env:)
        existing = Valpo::ServiceDependency.where(service_id: app.id, dependency_service_id: managed.id).first
        attributes = {status: "active", env_json: JSON.generate(env)}
        existing ? existing.update(attributes) : Valpo::ServiceDependency.create(attributes.merge(service_id: app.id, dependency_service_id: managed.id))
      end

      def restart_app_if_running(app, queue:, job_id:)
        return unless app.status == "running"
        return unless Valpo::Release.active_for_service(app.id)

        deployment_orchestrator_for.restart_service(service_id: app.id, queue: queue, job_id: job_id)
      end

      def find_app_service(service_id)
        service = find_service(service_id)
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def find_managed_service(service_id)
        service = find_service(service_id)
        raise Valpo::ValidationError, "Operation requires a managed service" unless service.managed?

        service
      end

      def find_service(service_id)
        Valpo::Service[service_id] || raise(Valpo::ValidationError, "Service not found: #{service_id}")
      end

      def validate_same_project!(app, managed)
        return if app.project_id == managed.project_id

        raise Valpo::ValidationError, "Service dependencies must stay within one project"
      end

      def runtime_for(queue: nil, job_id: nil)
        Runtime.new(config: config, docker: docker, queue: queue, job_id: job_id, sleeper: sleeper)
      end

      def deployment_orchestrator_for
        @deployment_orchestrator ||= Valpo::Deployments::Orchestrator.new(config: config, docker: docker, sleeper: sleeper)
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end
    end
  end
end
