# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("", "services") do |r|
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
              validate_keys!(payload, %w[image ref internal_port port healthcheck_path], "deployment")
              Valpo::Services::Definitions.validate_options!(type: service.kind, options: payload)
              port = optional_port(payload["internal_port"] || payload["port"])
              image = optional_string(payload, "image")
              ref = optional_string(payload, "ref")
              raise Valpo::ValidationError, "image and ref cannot be used together" if image && ref
              if image
                job_type = "deploy_registry_image"
                operation_payload = {image: image}
              else
                app_config = Valpo::AppServiceConfig[service.id]
                raise Valpo::ValidationError, "Service has no configured build target" unless app_config&.build_target_id
                job_type = "deploy_source"
                operation_payload = {ref: ref}.compact
              end
              response.status = 202
              Serializers.job(jobs.enqueue_service_operation(
                job_type, service_id: service.id,
                payload: operation_payload.merge(
                  project_id: service.project_id,
                  internal_port: port,
                  healthcheck_path: optional_healthcheck_path(payload["healthcheck_path"])
                )
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
    end
  end
end
