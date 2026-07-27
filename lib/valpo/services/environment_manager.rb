# frozen_string_literal: true

module Valpo
  module Services
    class EnvironmentManager
      def initialize(deployment_lifecycle: nil)
        @deployment_lifecycle = deployment_lifecycle
      end

      def set(service_id:, name:, value:, sensitive: true)
        service = find_app_service(service_id)
        validate_name_available!(service, name)
        variable = Valpo::ServiceEnvironmentVariable.where(service_id: service.id, name:).first
        changed = variable.nil? || variable.value != value.to_s || variable.sensitive != sensitive
        return variable unless changed

        variable ||= Valpo::ServiceEnvironmentVariable.new(service_id: service.id, name:)
        variable.sensitive = sensitive
        variable.value = value
        variable.save
        bump_revision(service)
        variable.refresh
      end

      def unset(service_id:, name:)
        service = find_app_service(service_id)
        variable = Valpo::ServiceEnvironmentVariable.where(service_id: service.id, name:).first
        raise Valpo::ValidationError, "Environment variable not found: #{name}" unless variable

        variable.destroy
        bump_revision(service)
        true
      end

      def reconcile(service_id:, queue:, job_id:)
        service = find_app_service(service_id)
        release = Valpo::Release.active_for_service(service.id) || Valpo::Release.ready_for_service(service.id)
        return service unless service.status == "running" || service.status == "ready"
        return service unless release
        return service if release.environment_revision == service.environment_revision

        deployment.restart_service(service_id: service.id, queue:, job_id:)
        release.refresh.update(environment_revision: service.refresh.environment_revision)
        service.refresh
      end

      private

      attr_reader :deployment_lifecycle

      def find_app_service(service_id)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found: #{service_id}" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def validate_name_available!(service, name)
        if Environment::RESERVED_KEYS.include?(name)
          raise Valpo::ConflictError, "Environment variable is managed by the platform: #{name}"
        end
        if Environment.managed_keys_for_service(service.id).include?(name)
          raise Valpo::ConflictError, "Environment variable is managed by a service dependency: #{name}"
        end
      end

      def bump_revision(service)
        Valpo::Service.where(id: service.id).update(
          environment_revision: Sequel[:environment_revision] + 1
        )
        service.refresh
      end

      def deployment
        @deployment_lifecycle ||= Valpo::Deployments::Lifecycle.new
      end
    end
  end
end
