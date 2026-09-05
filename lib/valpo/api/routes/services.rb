# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "services") do |r|
        # GET /v1/services — list services, optionally filtered by project.
        r.get true do
          query = validate_query(V1::Services::ListQueryContract)
          dataset = Valpo::Service.order(:created_at, :name)
          if query[:project]
            project = Valpo::References.project(query.fetch(:project))
            dataset = dataset.where(project_id: project.id)
          end
          dataset.all.map { V1::Services.render(it) }
        end

        r.on String do
          service = Valpo::Service[it]
          next not_found("Service not found") unless service

          r.on "logs" do
            # GET /v1/services/{service}/logs — read service logs.
            r.get true do
              query = validate_query(V1::Services::TailQueryContract)
              logs_for(service, tail: query.fetch(:tail, 200)).merge(service: V1::Services.render(service))
            end
          end

          r.on "restart" do
            # POST /v1/services/{service}/restart — enqueue a service restart.
            r.post true do
              validate_query
              enqueue_service_job("restart_service", service)
            end
          end

          r.on "stop" do
            # POST /v1/services/{service}/stop — enqueue a service stop.
            r.post true do
              validate_query
              enqueue_service_job("stop_service", service)
            end
          end

          r.on "dependencies" do
            # POST /v1/services/{service}/dependencies — bind a managed dependency.
            r.post true do
              validate_query
              require_app!(service)
              payload = validate_body(V1::Services::BindDependencyContract)
              dependency = Valpo::Service[payload.fetch(:dependency_service_id)]
              raise Valpo::ValidationError, "Managed service not found" unless dependency&.managed?

              response.status = 202
              V1::Jobs.render(jobs.enqueue_service_operation(
                "bind_service",
                service_id: service.id,
                payload: {project_id: service.project_id, dependency_service_id: dependency.id}
              ))
            end

            r.on String do |dependency_id|
              if r.delete?
                # DELETE /v1/services/{service}/dependencies/{dependency} — unbind a managed dependency.
                r.is do
                  validate_query
                  require_app!(service)
                  dependency = Valpo::Service[dependency_id]
                  raise Valpo::ValidationError, "Managed service not found" unless dependency&.managed?

                  response.status = 202
                  V1::Jobs.render(jobs.enqueue_service_operation(
                    "unbind_service",
                    service_id: service.id,
                    payload: {project_id: service.project_id, dependency_service_id: dependency.id}
                  ))
                end
              end
            end
          end

          r.on "deployments" do
            # POST /v1/services/{service}/deployments — enqueue a registry or source deployment.
            r.post true do
              validate_query
              require_app!(service)
              payload = validate_body(V1::Services::DeployContract)
              Valpo::Services::Registry.validate_options!(type: service.kind, options: payload)
              image = payload[:image]
              ref = payload[:ref]
              raise Valpo::ValidationError, "image and ref cannot be used together" if image && ref

              if image
                job_type = "deploy_registry_image"
                operation_payload = {image:}
              else
                app_config = Valpo::AppServiceConfig[service.id]
                unless app_config&.build_target_id
                  raise Valpo::ValidationError, "Service has no configured build target"
                end
                job_type = "deploy_source"
                operation_payload = {ref:}.compact
              end
              response.status = 202
              V1::Jobs.render(jobs.enqueue_service_operation(
                job_type,
                service_id: service.id,
                payload: operation_payload.merge(
                  project_id: service.project_id,
                  internal_port: payload[:internal_port],
                  healthcheck_path: payload[:healthcheck_path]
                )
              ))
            end
          end

          r.on "releases" do
            # GET /v1/services/{service}/releases — list application releases.
            r.get true do
              validate_query
              require_app!(service)
              Valpo::Release.where(service_id: service.id).order(Sequel.desc(:version)).all.map do
                V1::Services.render_release(it)
              end
            end
          end

          r.on "rollback" do
            # POST /v1/services/{service}/rollback — enqueue rollback to the prior release.
            r.post true do
              validate_query
              require_app!(service)
              enqueue_service_job("rollback_release", service)
            end
          end

          r.on "env" do
            # GET /v1/services/{service}/env — show effective service environment entries.
            r.get true do
              query = validate_query(V1::Services::EnvironmentQueryContract)
              require_app!(service)
              require_admin_credential! if query[:reveal] == "true"
              {
                service: V1::Services.render(service),
                env: Valpo::Services::Environment.entries_for_service(
                  service.id, reveal: query[:reveal] == "true"
                )
              }
            end

            r.on "reconcile" do
              # POST /v1/services/{service}/env/reconcile — apply the latest environment revision.
              r.post true do
                validate_query
                require_app!(service)
                response.status = 202
                V1::Jobs.render(jobs.enqueue_service_operation(
                  "reconcile_service_environment",
                  service_id: service.id,
                  payload: {project_id: service.project_id}
                ))
              end
            end

            r.on String do |name|
              if r.put?
                # PUT /v1/services/{service}/env/{name} — set a custom environment variable.
                r.is do
                  validate_query
                  require_app!(service)
                  payload = validate_body(V1::Services::SetEnvironmentVariableContract)
                  variable = nil
                  job = jobs.enqueue_service_operation(
                    "reconcile_service_environment",
                    service_id: service.id,
                    payload: {project_id: service.project_id}
                  ) do
                    variable = environment_manager.set(
                      service_id: service.id,
                      name:,
                      value: payload.fetch(:value),
                      sensitive: payload.fetch(:sensitive, true)
                    )
                  end
                  response.status = 202
                  {
                    variable: V1::Services.render_environment_variable(variable),
                    job: V1::Jobs.render(job)
                  }
                end
              end

              if r.delete?
                # DELETE /v1/services/{service}/env/{name} — remove a custom environment variable.
                r.is do
                  validate_query
                  require_app!(service)
                  job = jobs.enqueue_service_operation(
                    "reconcile_service_environment",
                    service_id: service.id,
                    payload: {project_id: service.project_id}
                  ) do
                    environment_manager.unset(service_id: service.id, name:)
                  end
                  response.status = 202
                  {deleted: true, name:, job: V1::Jobs.render(job)}
                end
              end
            end
          end

          r.on "domains" do
            require_web!(service)

            # GET /v1/services/{service}/domains — list service domains.
            r.get true do
              validate_query
              Valpo::Domain.where(service_id: service.id).order(:hostname).all.map do
                V1::Services.render_domain(it)
              end
            end

            # POST /v1/services/{service}/domains — create and verify a custom domain.
            r.post true do
              validate_query
              payload = validate_body(V1::Services::CreateDomainContract)
              domain = nil
              job_payload = {project_id: service.project_id}
              job = jobs.enqueue_service_operation(
                "verify_domain", service_id: service.id, payload: job_payload
              ) do
                domain = Valpo::Domain.create(service_id: service.id, hostname: payload.fetch(:hostname))
                job_payload[:domain_id] = domain.id
              end
              response.status = 202
              {domain: V1::Services.render_domain(domain), job: V1::Jobs.render(job)}
            end

            r.on String do
              domain = Valpo::Domain.where(service_id: service.id, id: it).first ||
                Valpo::Domain.where(service_id: service.id, hostname: it.downcase).first
              next not_found("Domain not found") unless domain

              r.on "verify" do
                # POST /v1/services/{service}/domains/{domain}/verify — recheck a domain.
                r.post true do
                  validate_query
                  response.status = 202
                  V1::Jobs.render(jobs.enqueue_service_operation(
                    "verify_domain",
                    service_id: service.id,
                    payload: {project_id: service.project_id, domain_id: domain.id}
                  ))
                end
              end

              if r.delete?
                # DELETE /v1/services/{service}/domains/{domain} — remove a custom domain.
                r.is do
                  validate_query
                  if domain.kind == "generated"
                    raise Valpo::ValidationError, "Generated domains are managed by the platform app domain"
                  end
                  if service.status == "running" && domain.verified? &&
                      Valpo::Domain.where(service_id: service.id, status: "verified").count == 1
                    raise Valpo::ConflictError, "Stop the web service before removing its last verified domain"
                  end

                  job = jobs.enqueue_service_operation(
                    "apply_caddy_config", service_id: service.id, payload: {project_id: service.project_id}
                  ) do
                    if domain.verified? && Valpo::Domain.where(service_id: service.id, status: "verified").count == 1
                      Valpo::Release.active_for_service(service.id)&.ready!
                    end
                    domain.destroy
                  end
                  {deleted: true, job: V1::Jobs.render(job)}
                end
              end
            end
          end

          # GET /v1/services/{service} — show a service.
          r.get true do
            validate_query
            V1::Services.render(service)
          end

          if r.patch?
            # PATCH /v1/services/{service} — update application configuration.
            r.is do
              validate_query
              require_app!(service)
              payload = validate_body(V1::Services::UpdateContract)

              runtime = {}
              if payload.key?(:command)
                runtime["command"] = Valpo::Services::Registry.normalize_command(payload.fetch(:command))
              end
              runtime["internal_port"] = payload[:internal_port] if payload.key?(:internal_port)
              runtime["healthcheck_path"] = payload[:healthcheck_path] if payload.key?(:healthcheck_path)
              Valpo::Services::Registry.validate_options!(type: service.kind, options: runtime)

              configuration = if payload.key?(:source) || payload.key?(:build)
                desired = Valpo::Sources::ServiceConfigurator.new.desired_for(
                  service:,
                  source_changes: payload[:source],
                  build_changes: payload[:build]
                )
                {"source" => desired.fetch(:source), "build" => desired.fetch(:build)}
              end
              deploy = payload.fetch(:deploy, false)
              if deploy && !configuration && Valpo::AppServiceConfig[service.id]&.build_target_id.nil?
                raise Valpo::ValidationError, "Service has no configured build target"
              end
              if runtime.empty? && configuration.nil? && !deploy
                raise Valpo::ValidationError, "At least one service update option is required"
              end

              response.status = 202
              V1::Jobs.render(jobs.enqueue_service_operation(
                "update_app_service",
                service_id: service.id,
                payload: {
                  project_id: service.project_id,
                  configuration:,
                  runtime:,
                  deploy:
                }
              ))
            end
          end

          if r.delete?
            # DELETE /v1/services/{service} — enqueue forced service deletion.
            r.is do
              query = validate_query(V1::Services::DeleteQueryContract)
              unless query[:force] == "true"
                raise Valpo::ValidationError, "force=true is required to delete a service"
              end

              response.status = 202
              V1::Jobs.render(jobs.enqueue_service_operation(
                "delete_service", service_id: service.id, payload: {project_id: service.project_id, force: true}
              ))
            end
          end
        end
        not_found("Route not found")
      end
    end
  end
end
