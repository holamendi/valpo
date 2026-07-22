# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "projects") do |r|
        r.on "apply" do
          # POST /v1/projects/apply — preview or enqueue a project manifest.
          r.post true do
            validate_query
            payload = validate_body(V1::Projects::ApplyContract)
            manifest = Valpo::Manifests::ProjectManifest.parse(payload.fetch(:manifest))
            if payload.fetch(:dry_run, false)
              manifest_planner.call(manifest)
            else
              response.status = 202
              V1::Jobs.render(jobs.enqueue_manifest_operation(
                project_name: manifest.dig("project", "name"), manifest:
              ))
            end
          end
        end

        # GET /v1/projects — list projects.
        r.get true do
          validate_query
          Valpo::Project.order(:created_at, :name).all.map { V1::Projects.render(it) }
        end

        # POST /v1/projects — create a project.
        r.post true do
          validate_query
          payload = validate_body(V1::Projects::CreateContract)
          project = Valpo::Project.create(name: payload.fetch(:name))
          response.status = 201
          V1::Projects.render(project)
        end

        r.on String do
          project = Valpo::Project.find_by_id_or_name(it)
          next not_found("Project not found") unless project

          r.on "services" do
            # GET /v1/projects/{project}/services — list a project's services.
            r.get true do
              validate_query
              services_for_project(project).map { V1::Services.render(it) }
            end

            # POST /v1/projects/{project}/services — create a service in a project.
            r.post true do
              validate_query
              payload = validate_body(V1::Services::CreateContract)
              type = payload.fetch(:type)
              Valpo::Services::Registry.validate_options!(type:, options: payload)
              command = payload.fetch(:command, [])
              port = payload[:internal_port]
              healthcheck_path = payload[:healthcheck_path]

              if payload[:source]
                unless Valpo::Services::Registry.app_type?(type)
                  raise Valpo::ValidationError, "source is only valid for web and worker services"
                end

                configuration = Valpo::Sources::ServiceConfigurator.new.normalize_create(
                  source: payload.fetch(:source),
                  build: payload[:build]
                )
                response.status = 202
                next V1::Jobs.render(jobs.enqueue_project_operation(
                  "create_source_service",
                  project_id: project.id,
                  payload: {
                    service: {
                      name: payload.fetch(:name),
                      type:,
                      command:,
                      internal_port: port,
                      healthcheck_path:
                    },
                    source: configuration.fetch(:source),
                    build: configuration.fetch(:build),
                    deploy: payload.fetch(:deploy, false)
                  }
                ))
              end
              raise Valpo::ValidationError, "build requires source" if payload[:build]
              raise Valpo::ValidationError, "deploy requires source" if payload[:deploy]

              service = nil
              job = nil
              Valpo::Database.connection.transaction do
                active = jobs.active_project_job(project.id, types: Valpo::Jobs::Queue::PROJECT_OPERATION_TYPES)
                if active
                  raise Valpo::ConflictError, "Project already has an active #{active.type} job: #{active.id}"
                end

                service = Valpo::Services::Creator.call(
                  project_id: project.id,
                  name: payload.fetch(:name),
                  type:,
                  version: payload[:version],
                  command:,
                  internal_port: port,
                  healthcheck_path:
                )
                if service.managed?
                  job = jobs.enqueue_service_operation(
                    "provision_service", service_id: service.id, payload: {project_id: project.id}
                  )
                end
              end
              response.status = job ? 202 : 201
              {
                service: V1::Services.render(service.refresh),
                job: job && V1::Jobs.render(job)
              }
            end

            r.on String do |service_reference|
              # GET /v1/projects/{project}/services/{service} — show a project service.
              r.get true do
                validate_query
                service = Valpo::Service.where(project_id: project.id, id: service_reference).first ||
                  Valpo::Service.where(project_id: project.id, name: service_reference).first
                next not_found("Service not found") unless service

                V1::Services.render(service)
              end
            end
          end

          r.on "sources" do
            # GET /v1/projects/{project}/sources — list a project's sources.
            r.get true do
              validate_query
              Valpo::Source.where(project_id: project.id).order(:name).all.map do
                V1::Projects.render_source(it)
              end
            end
          end

          r.on "logs" do
            # GET /v1/projects/{project}/logs — aggregate logs for a project.
            r.get true do
              query = validate_query(V1::Projects::LogsQueryContract)
              aggregate_logs(project, tail: query[:tail], filter: query[:service])
            end
          end

          # GET /v1/projects/{project} — show a project.
          r.get true do
            validate_query
            V1::Projects.render(project)
          end

          if r.delete?
            # DELETE /v1/projects/{project} — enqueue deletion of an empty project.
            r.is do
              validate_query
              unless Valpo::Service.where(project_id: project.id).empty?
                raise Valpo::ConflictError, "Project still has services"
              end

              response.status = 202
              V1::Jobs.render(jobs.enqueue_project_operation("delete_project", project_id: project.id))
            end
          end
        end
        not_found("Route not found")
      end
    end
  end
end
