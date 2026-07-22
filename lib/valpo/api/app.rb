# frozen_string_literal: true

require "json"
require "roda"

module Valpo
  module API
    class App < Roda
      include Authentication
      include RequestHelpers

      plugin :json
      plugin :not_found do
        response["Content-Type"] = "application/json"
        {error: "not_found", message: "Route not found"}
      end
      plugin :json_parser,
        wrap: :unless_hash,
        include_request: true,
        parser: lambda { |body, request|
          request.env["valpo.json_body"] = true
          JSON.parse(body)
        },
        error_handler: ->(_request) { raise BadRequest, "Request body must be valid JSON" }
      plugin :hash_branches
      plugin :error_handler do
        status, code, message = case it
        when BadRequest
          [400, "invalid_request", it.message]
        when Valpo::ValidationError, Sequel::ValidationFailed
          [422, "validation_failed", it.message]
        when Valpo::ConflictError, Sequel::UniqueConstraintViolation
          [409, "conflict", it.message]
        else
          warn("[valpo-api] #{it.class}: #{it.message}\n#{Array(it.backtrace).join("\n")}")
          [500, "internal_error", "An internal error occurred"]
        end
        response.status = status
        payload = {error: code, message:}
        payload[:details] = it.details if it.is_a?(BadRequest) && it.details&.any?
        payload
      end

      Dir[File.join(__dir__, "routes", "*.rb")].sort.each { require it }

      route do |r|
        response["Content-Type"] = "application/json"
        unauthorized = authenticate_request
        next unauthorized if unauthorized

        # GET / — describe the API service.
        r.root do
          validate_query
          {service: "valpo-api", version: Valpo::VERSION}
        end
        r.on("health") do
          # GET /health — report API process health.
          r.get true do
            validate_query
            {ok: true, service: "valpo-api", version: Valpo::VERSION}
          end
          not_found("Route not found")
        end
        r.on("v1") do
          r.hash_branches("/v1")
          not_found("Route not found")
        end
        not_found("Route not found")
      end

      private

      def jobs
        Valpo::Jobs::Queue.new
      end

      def deployment_lifecycle
        Valpo::Deployments::Lifecycle.new(config: Valpo.config || Valpo::Config.load)
      end

      def managed_service_lifecycle
        Valpo::Services::ManagedLifecycle.new(config: Valpo.config || Valpo::Config.load)
      end

      def manifest_reconciler
        Valpo::Manifests::Reconciler.new
      end

      def manifest_planner
        Valpo::Manifests::Planner.new
      end

      def services_for_project(project)
        Valpo::Service.where(project_id: project.id).order(:created_at, :name).all
      end

      def enqueue_service_job(type, service)
        response.status = 202
        V1::Jobs.render(jobs.enqueue_service_operation(type, service_id: service.id, payload: {project_id: service.project_id}))
      end

      def logs_for(service, tail:)
        if service.app?
          deployment_lifecycle.app_logs(service_id: service.id, tail:)
        else
          managed_service_lifecycle.service_logs(service_id: service.id, tail:)
        end
      end

      def aggregate_logs(project, tail:, filter:)
        services = services_for_project(project)
        services.select! { it.name == filter } if filter && !filter.empty?
        entries = services.filter_map do
          logs_for(it, tail:).merge(service_id: it.id, service_name: it.name, kind: it.kind)
        rescue Valpo::ValidationError => e
          {service_id: it.id, service_name: it.name, kind: it.kind, error: e.message}
        end
        {project: V1::Projects.render(project), logs: entries}
      end

      def require_app!(service)
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?
      end

      def require_web!(service)
        raise Valpo::ValidationError, "Operation requires a web service" unless service.web?
      end
    end
  end
end
