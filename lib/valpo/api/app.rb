# frozen_string_literal: true

require "json"
require "roda"
require "valpo"
require "valpo/api/serializers"
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
          when Sequel::UniqueConstraintViolation
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
            r.is do
              r.get do
                project = Valpo::Project.find_by_id_or_name(id)
                next not_found("Project not found") unless project

                Serializers.project(project)
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
    end
  end
end
