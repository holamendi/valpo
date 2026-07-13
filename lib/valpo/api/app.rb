# frozen_string_literal: true

require "json"
require "roda"

module Valpo
  module API
    class App < Roda
      include Authentication
      include RequestHelpers

      plugin :json
      plugin :hash_branches
      plugin :error_handler do |error|
        response.status = case error
        when Valpo::ValidationError, Sequel::ValidationFailed then 422
        when Valpo::ConflictError, Sequel::UniqueConstraintViolation then 409
        else 500
        end
        {error: error.class.name, message: error.message}
      end

      Dir[File.join(__dir__, "routes", "*.rb")].sort.each { |path| require path }

      route do |r|
        response["Content-Type"] = "application/json"
        unauthorized = authenticate_request
        next unauthorized if unauthorized

        r.root { {service: "valpo-api", version: Valpo::VERSION} }
        r.on("health") { r.get { {ok: true, service: "valpo-api", version: Valpo::VERSION} } }
        r.hash_branches("")
      end

      private

      def jobs
        Valpo::Jobs::Queue.new
      end

      def deploy_orchestrator
        Valpo::Deployments::Orchestrator.new(config: Valpo.config || Valpo::Config.load)
      end

      def service_orchestrator
        Valpo::Services::Orchestrator.new(config: Valpo.config || Valpo::Config.load)
      end

      def manifest_reconciler
        Valpo::Manifests::Reconciler.new
      end

      def services_for_project(project)
        Valpo::Service.where(project_id: project.id).order(:created_at, :name).all
      end

      def enqueue_service_job(type, service)
        response.status = 202
        Serializers.job(jobs.enqueue_service_operation(type, service_id: service.id, payload: {project_id: service.project_id}))
      end

      def logs_for(service, tail:)
        service.app? ? deploy_orchestrator.app_logs(service_id: service.id, tail: tail) : service_orchestrator.service_logs(service_id: service.id, tail: tail)
      end

      def aggregate_logs(project, tail:, filter:)
        services = services_for_project(project)
        services.select! { |service| service.name == filter } if filter && !filter.empty?
        entries = services.filter_map do |service|
          logs_for(service, tail: tail).merge(service_id: service.id, service_name: service.name, kind: service.kind)
        rescue Valpo::ValidationError => e
          {service_id: service.id, service_name: service.name, kind: service.kind, error: e.message}
        end
        {project: Serializers.project(project), logs: entries}
      end

      def require_app!(service)
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?
      end

      def require_web!(service)
        raise Valpo::ValidationError, "Operation requires a web service" unless service.web?
      end

      def optional_port(value)
        return nil if value.nil? || value.to_s.empty?
        validate_port!(parse_integer(value, "internal_port"), "internal_port")
      end

      def truthy_param?(value)
        %w[1 true yes].include?(value.to_s.downcase)
      end
    end
  end
end
