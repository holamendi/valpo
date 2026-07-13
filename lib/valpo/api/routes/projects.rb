# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("", "projects") do |r|
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
                validate_keys!(payload, %w[name type version command internal_port port healthcheck_path], "service")
                type = required_string(payload, "type")
                Valpo::Services::Definitions.validate_options!(type: type, options: payload)
                service = nil
                job = nil
                Valpo::Database.connection.transaction do
                  active = jobs.active_project_job(project.id, types: Valpo::Jobs::Queue::PROJECT_OPERATION_TYPES)
                  raise Valpo::ConflictError, "Project already has an active #{active.type} job: #{active.id}" if active

                  service = Valpo::Services::Catalog.create_service(
                    project_id: project.id,
                    name: required_string(payload, "name"),
                    type: type,
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

            r.on String do |service_reference|
              r.get do
                service = Valpo::Service.where(project_id: project.id, id: service_reference).first ||
                  Valpo::Service.where(project_id: project.id, name: service_reference).first
                next not_found("Service not found") unless service

                Serializers.service(service)
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
    end
  end
end
