# frozen_string_literal: true

module Valpo
  module Services
    class DependencyManager
      def initialize(
        config: Valpo.config || Valpo::Config.load,
        docker: Valpo::Docker::Client.new,
        deployment_lifecycle: nil,
        sleeper: Kernel
      )
        @config = config
        @docker = docker
        @deployment_lifecycle = deployment_lifecycle
        @sleeper = sleeper
      end

      def bind_service(service_id:, dependency_service_id:, queue:, job_id:)
        app = find_app_service(service_id)
        managed = find_managed_service(dependency_service_id)
        validate_same_project!(app, managed)
        raise Valpo::ValidationError, "Managed service must be running before binding" unless managed.status == "running"

        env = Registry.binding_environment(managed)
        conflicts = Environment.conflicting_keys(
          service_id: app.id, dependency_service_id: managed.id, env:
        )
        unless conflicts.empty?
          raise Valpo::ConflictError, "App service already has environment keys: #{conflicts.sort.join(", ")}"
        end

        existing = Valpo::ServiceDependency.where(
          service_id: app.id, dependency_service_id: managed.id
        ).first
        previous = existing&.values&.slice(:status)
        dependency = upsert_dependency(app:, managed:, existing:)
        event(queue, job_id, "system", "Bound #{managed.name} to #{app.name}")
        restart_app_if_running(app, queue:, job_id:)
        dependency
      rescue
        restore_dependency(dependency, previous)
        raise
      end

      def unbind_service(service_id:, dependency_service_id:, queue:, job_id:)
        app = find_app_service(service_id)
        managed = find_managed_service(dependency_service_id)
        dependency = Valpo::ServiceDependency.where(
          service_id: app.id, dependency_service_id: managed.id
        ).first
        raise Valpo::ValidationError, "Service dependency not found" unless dependency

        dependency.transition_to!("deleting")
        restart_app_if_running(app, queue:, job_id:)
        dependency.destroy
        event(queue, job_id, "system", "Unbound #{managed.name} from #{app.name}")
        true
      rescue
        dependency&.transition_to!("active") if dependency&.pk && Valpo::ServiceDependency[dependency.id]
        raise
      end

      def restart_app_if_running(app, queue:, job_id:)
        return unless app.status == "running"
        return unless Valpo::Release.active_for_service(app.id)

        deployment_lifecycle.restart_service(service_id: app.id, queue:, job_id:)
      end

      private

      attr_reader :config, :docker, :sleeper

      def upsert_dependency(app:, managed:, existing:)
        attributes = {status: "active"}
        return existing.transition_to!("active") if existing

        Valpo::ServiceDependency.create(
          attributes.merge(service_id: app.id, dependency_service_id: managed.id)
        )
      end

      def restore_dependency(dependency, previous)
        return unless dependency&.pk && Valpo::ServiceDependency[dependency.id]

        previous ? dependency.transition_to!(previous.fetch(:status)) : dependency.destroy
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

      def deployment_lifecycle
        @deployment_lifecycle ||= Valpo::Deployments::Lifecycle.new(
          config:, docker:, sleeper:
        )
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end
    end
  end
end
