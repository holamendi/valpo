# frozen_string_literal: true

require "json"
require "roda"
require "valpo"
require "valpo/api/serializers"
require "valpo/deployments/orchestrator"
require "valpo/jobs/queue"

module Valpo
  module API
    class App < Roda
      plugin :json
      plugin :error_handler do |error|
        response.status =
          case error
          when Valpo::ValidationError, Sequel::ValidationFailed
            422
          when Valpo::ConflictError, Sequel::UniqueConstraintViolation
            409
          else
            500
          end

        { error: error.class.name, message: error.message }
      end

      route do |r|
        response["Content-Type"] = "application/json"

        r.root do
          { service: "valpo-api", version: Valpo::VERSION }
        end

        r.on "health" do
          r.get do
            { ok: true, service: "valpo-api", version: Valpo::VERSION }
          end
        end

        r.on "projects" do
          r.is do
            r.get do
              Valpo::Project.order(:created_at, :name).all.map { |project| Serializers.project(project) }
            end

            r.post do
              payload = parse_json_body
              project = Valpo::Project.create(
                name: payload["name"],
                type: payload.fetch("type", "container")
              )
              response.status = 201
              Serializers.project(project)
            end
          end

          r.on String do |id|
            project = Valpo::Project.find_by_id_or_name(id)
            next not_found("Project not found") unless project

            r.is do
              r.get do
                Serializers.project(project)
              end
            end

            r.on "deployments" do
              r.post do
                validate_container_project!(project)
                payload = parse_json_body
                internal_port = required_integer(payload, "internal_port", fallback_key: "port")
                job = jobs.enqueue_project_operation(
                  "deploy_registry_image",
                  project_id: project.id,
                  payload: {
                    image: required_string(payload, "image"),
                    internal_port: validate_port!(internal_port, "internal_port"),
                    healthcheck_path: optional_healthcheck_path(payload["healthcheck_path"])
                  }
                )
                response.status = 202
                Serializers.job(job)
              end
            end

            r.on "releases" do
              r.get do
                Valpo::Release.where(project_id: project.id).order(Sequel.desc(:version)).all.map { |release| Serializers.release(release) }
              end
            end

            r.on "rollback" do
              r.post do
                validate_container_project!(project)
                job = jobs.enqueue_project_operation("rollback_release", project_id: project.id)
                response.status = 202
                Serializers.job(job)
              end
            end

            r.on "stop" do
              r.post do
                validate_container_project!(project)
                job = jobs.enqueue_project_operation("stop_project", project_id: project.id)
                response.status = 202
                Serializers.job(job)
              end
            end

            r.on "restart" do
              r.post do
                validate_container_project!(project)
                job = jobs.enqueue_project_operation("restart_project", project_id: project.id)
                response.status = 202
                Serializers.job(job)
              end
            end

            r.on "domains" do
              r.is do
                r.get do
                  Valpo::Domain.where(project_id: project.id).order(:hostname).all.map { |domain| Serializers.domain(domain) }
                end

                r.post do
                  payload = parse_json_body
                  domain = nil
                  job = jobs.enqueue_project_operation("apply_caddy_config", project_id: project.id) do
                    domain = Valpo::Domain.create(project_id: project.id, hostname: required_string(payload, "hostname"))
                  end
                  response.status = 201
                  { domain: Serializers.domain(domain), job: Serializers.job(job) }
                end
              end

              r.on String do |domain_id|
                r.is do
                  next unless r.delete?

                  domain = Valpo::Domain.where(project_id: project.id, id: domain_id).first ||
                           Valpo::Domain.where(project_id: project.id, hostname: domain_id.downcase).first
                  next not_found("Domain not found") unless domain

                  job = jobs.enqueue_project_operation("apply_caddy_config", project_id: project.id) do
                    domain.destroy
                  end
                  { deleted: true, job: Serializers.job(job) }
                end
              end
            end

            r.on "logs" do
              r.get do
                validate_container_project!(project)
                tail = optional_positive_integer(request.params["tail"], "tail")
                deploy_orchestrator.app_logs(project_id: project.id, tail: tail)
              end
            end
          end
        end

        r.on "jobs" do
          r.is do
            r.get do
              jobs.list.map { |job| Serializers.job(job) }
            end
          end

          r.on String do |id|
            r.on "events" do
              r.get do
                job = jobs.find(id)
                next not_found("Job not found") unless job

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

      def parse_json_body
        body = request.body.read
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        raise Valpo::ValidationError, "Request body must be valid JSON"
      end

      def not_found(message)
        response.status = 404
        { error: "not_found", message: message }
      end

      def required_string(payload, key)
        value = payload[key]
        raise Valpo::ValidationError, "#{key} is required" if value.nil? || value.to_s.strip.empty?

        value
      end

      def required_integer(payload, key, fallback_key: nil)
        value = payload[key]
        value = payload[fallback_key] if value.nil? && fallback_key
        raise Valpo::ValidationError, "#{key} is required" if value.nil? || value.to_s.strip.empty?

        parse_integer(value, key)
      end

      def optional_positive_integer(value, key)
        return nil if value.nil? || value.to_s.strip.empty?

        integer = parse_integer(value, key)
        raise Valpo::ValidationError, "#{key} must be greater than 0" unless integer.positive?

        integer
      end

      def parse_integer(value, key)
        Integer(value)
      rescue ArgumentError, TypeError
        raise Valpo::ValidationError, "#{key} must be an integer"
      end

      def validate_port!(value, key)
        raise Valpo::ValidationError, "#{key} must be between 1 and 65535" unless value.between?(1, 65_535)

        value
      end

      def optional_healthcheck_path(value)
        return nil if value.nil? || value.to_s.strip.empty?

        path = value.to_s
        raise Valpo::ValidationError, "healthcheck_path must start with /" unless path.start_with?("/")

        path
      end

      def validate_container_project!(project)
        raise Valpo::ValidationError, "Only container projects can use this endpoint" unless project.type == "container"
      end
    end
  end
end
