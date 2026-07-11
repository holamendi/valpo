# frozen_string_literal: true

require "json"
require "roda"
require "valpo"
require "valpo/api/authentication"
require "valpo/api/request_helpers"
require "valpo/api/serializers"
require "valpo/deployments/orchestrator"
require "valpo/jobs/queue"
require "valpo/manifests/project_manifest"
require "valpo/manifests/reconciler"
require "valpo/models/build_target"
require "valpo/models/domain"
require "valpo/models/release"
require "valpo/models/service"
require "valpo/models/service_dependency"
require "valpo/models/source"
require "valpo/references"
require "valpo/services/catalog"
require "valpo/services/environment"
require "valpo/services/orchestrator"

module Valpo
  module API
    class App < Roda
      include Authentication
      include RequestHelpers

      plugin :json
      plugin :error_handler do |error|
        response.status = case error
        when Valpo::ValidationError, Sequel::ValidationFailed then 422
        when Valpo::ConflictError, Sequel::UniqueConstraintViolation then 409
        else 500
        end
        {error: error.class.name, message: error.message}
      end

      route do |r|
        response["Content-Type"] = "application/json"
        unauthorized = authenticate_request
        next unauthorized if unauthorized

        r.root { {service: "valpo-api", version: Valpo::VERSION} }
        r.on("health") { r.get { {ok: true, service: "valpo-api", version: Valpo::VERSION} } }
        r.on("system", "repair") do
          r.post do
            response.status = 202
            Serializers.job(jobs.enqueue("repair_system"))
          end
        end

        r.on "projects" do
          r.on "apply" do
            r.post do
              payload = parse_json_body
              manifest = Valpo::Manifests::ProjectManifest.parse(required_string(payload, "manifest"))
              if payload["dry_run"] == true
                manifest_reconciler.preview(manifest)
              else
                response.status = 202
                Serializers.job(jobs.enqueue_manifest_operation(
                  project_name: manifest.dig("project", "name"), manifest: manifest
                ))
              end
            end
          end

          r.is do
            r.get { Valpo::Project.order(:created_at, :name).all.map { |project| Serializers.project(project) } }
            r.post do
              project = Valpo::Project.create(name: required_string(parse_json_body, "name"))
              response.status = 201
              Serializers.project(project)
            end
          end

          r.on String do |reference|
            project = Valpo::Project.find_by_id_or_name(reference)
            next not_found("Project not found") unless project

            r.on "services" do
              r.is do
                r.get { services_for_project(project).map { |service| Serializers.service(service) } }
                r.post do
                  payload = parse_json_body
                  service = nil
                  job = nil
                  Valpo::Database.connection.transaction do
                    active = jobs.active_project_job(project.id, types: Valpo::Jobs::Queue::PROJECT_OPERATION_TYPES)
                    raise Valpo::ConflictError, "Project already has an active #{active.type} job: #{active.id}" if active

                    service = Valpo::Services::Catalog.create_service(
                      project_id: project.id,
                      name: required_string(payload, "name"),
                      type: required_string(payload, "type"),
                      version: payload["version"],
                      command: payload.fetch("command", []),
                      internal_port: optional_port(payload["internal_port"] || payload["port"]),
                      healthcheck_path: optional_healthcheck_path(payload["healthcheck_path"])
                    )
                    if service.managed?
                      job = jobs.enqueue_service_operation("provision_service", service_id: service.id, payload: {project_id: project.id})
                    end
                  end
                  response.status = job ? 202 : 201
                  {service: Serializers.service(service.refresh), job: job && Serializers.job(job)}
                end
              end
            end

            r.on "sources" do
              r.get { Valpo::Source.where(project_id: project.id).order(:name).all.map { |source| Serializers.source(source) } }
            end

            r.on "logs" do
              r.get do
                tail = optional_positive_integer(request.params["tail"], "tail")
                filter = request.params["service"]
                aggregate_logs(project, tail: tail, filter: filter)
              end
            end

            r.is do
              r.get { Serializers.project(project) }
              if r.delete?
                raise Valpo::ConflictError, "Project still has services" unless Valpo::Service.where(project_id: project.id).empty?
                response.status = 202
                Serializers.job(jobs.enqueue_project_operation("delete_project", project_id: project.id))
              end
            end
          end
        end

        r.on "services" do
          r.is do
            r.get do
              dataset = Valpo::Service.order(:created_at, :name)
              if request.params["project"] && !request.params["project"].empty?
                project = Valpo::References.project(request.params["project"])
                dataset = dataset.where(project_id: project.id)
              end
              dataset.all.map { |service| Serializers.service(service) }
            end
          end

          r.on String do |id|
            service = Valpo::Service[id]
            next not_found("Service not found") unless service

            r.on "logs" do
              r.get do
                logs = logs_for(service, tail: optional_positive_integer(request.params["tail"], "tail"))
                logs.merge(service: Serializers.service(service))
              end
            end

            r.on "restart" do
              r.post { enqueue_service_job("restart_service", service) }
            end

            r.on "stop" do
              r.post { enqueue_service_job("stop_service", service) }
            end

            r.on "dependencies" do
              r.is do
                r.post do
                  require_app!(service)
                  dependency = Valpo::Service[required_string(parse_json_body, "dependency_service_id")]
                  raise Valpo::ValidationError, "Managed service not found" unless dependency&.managed?
                  response.status = 202
                  Serializers.job(jobs.enqueue_service_operation(
                    "bind_service", service_id: service.id,
                    payload: {project_id: service.project_id, dependency_service_id: dependency.id}
                  ))
                end
              end
              r.on String do |dependency_id|
                if r.delete?
                  require_app!(service)
                  dependency = Valpo::Service[dependency_id]
                  raise Valpo::ValidationError, "Managed service not found" unless dependency&.managed?
                  response.status = 202
                  Serializers.job(jobs.enqueue_service_operation(
                    "unbind_service", service_id: service.id,
                    payload: {project_id: service.project_id, dependency_service_id: dependency.id}
                  ))
                end
              end
            end

            r.on "deployments" do
              r.post do
                require_app!(service)
                payload = parse_json_body
                port = optional_port(payload["internal_port"] || payload["port"])
                response.status = 202
                Serializers.job(jobs.enqueue_service_operation(
                  "deploy_registry_image", service_id: service.id,
                  payload: {
                    project_id: service.project_id, image: required_string(payload, "image"), internal_port: port,
                    healthcheck_path: optional_healthcheck_path(payload["healthcheck_path"])
                  }
                ))
              end
            end

            r.on "releases" do
              r.get do
                require_app!(service)
                Valpo::Release.where(service_id: service.id).order(Sequel.desc(:version)).all.map { |release| Serializers.release(release) }
              end
            end

            r.on "rollback" do
              r.post do
                require_app!(service)
                enqueue_service_job("rollback_release", service)
              end
            end

            r.on "env" do
              r.get do
                require_app!(service)
                {service: Serializers.service(service), env: Valpo::Services::Environment.entries_for_service(service.id, reveal: truthy_param?(request.params["reveal"]))}
              end
            end

            r.on "domains" do
              require_web!(service)
              r.is do
                r.get { Valpo::Domain.where(service_id: service.id).order(:hostname).all.map { |domain| Serializers.domain(domain) } }
                r.post do
                  hostname = required_string(parse_json_body, "hostname")
                  domain = nil
                  job = jobs.enqueue_service_operation("apply_caddy_config", service_id: service.id, payload: {project_id: service.project_id}) do
                    domain = Valpo::Domain.create(service_id: service.id, hostname: hostname)
                  end
                  response.status = 201
                  {domain: Serializers.domain(domain), job: Serializers.job(job)}
                end
              end
              r.on String do |domain_ref|
                if r.delete?
                  domain = Valpo::Domain.where(service_id: service.id, id: domain_ref).first ||
                    Valpo::Domain.where(service_id: service.id, hostname: domain_ref.downcase).first
                  next not_found("Domain not found") unless domain
                  job = jobs.enqueue_service_operation("apply_caddy_config", service_id: service.id, payload: {project_id: service.project_id}) do
                    domain.destroy
                  end
                  {deleted: true, job: Serializers.job(job)}
                end
              end
            end

            r.is do
              r.get { Serializers.service(service) }
              if r.delete?
                raise Valpo::ValidationError, "force=true is required to delete a service" unless truthy_param?(request.params["force"])
                response.status = 202
                Serializers.job(jobs.enqueue_service_operation(
                  "delete_service", service_id: service.id, payload: {project_id: service.project_id, force: true}
                ))
              end
            end
          end
        end

        r.on "jobs" do
          r.is { r.get { jobs.list.map { |job| Serializers.job(job) } } }
          r.on String do |id|
            r.on("events") do
              r.get do
                next not_found("Job not found") unless jobs.find(id)
                jobs.events(id).map { |event| Serializers.job_event(event) }
              end
            end
            r.is do
              r.get do
                job = jobs.find(id)
                next not_found("Job not found") unless job
                Serializers.job(job)
              end
            end
          end
        end
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
