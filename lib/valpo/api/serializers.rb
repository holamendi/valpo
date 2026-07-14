# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module API
    module Serializers
      module_function

      def project(record)
        fields(record, :id, :name, :manifest_digest, :last_applied_at, :created_at, :updated_at).merge(
          service_count: Valpo::Service.where(project_id: record.id).count,
          source_count: Valpo::Source.where(project_id: record.id).count
        )
      end

      def source(record)
        fields(record, :id, :project_id, :name, :provider, :repository, :ref, :auto_deploy, :status, :created_at, :updated_at)
      end

      def build_target(record)
        fields(record, :id, :project_id, :source_id, :name, :dockerfile, :context, :created_at, :updated_at)
      end

      def service(record)
        output = fields(record, :id, :project_id, :name, :kind, :status, :created_at, :updated_at)
        output[:reference] = "#{record.project.name}/#{record.name}"
        if record.app?
          config = Valpo::AppServiceConfig[record.id]
          build = config.build_target
          source = build&.source
          active_release = Valpo::Release.active_for_service(record.id)
          output[:app] = fields(config, :build_target_id, :internal_port, :healthcheck_path).merge(
            command: config.command,
            port_mode: config.internal_port ? "explicit" : "automatic",
            resolved_internal_port: active_release&.internal_port,
            source: source && source(source),
            build: build && build_target(build)
          )
        else
          config = Valpo::ManagedServiceConfig[record.id]
          output[:managed] = fields(
            config, :version, :image, :plan, :container_name, :volume_name, :internal_host, :internal_port
          )
        end
        output[:dependencies] = Valpo::ServiceDependency.where(service_id: record.id).order(:created_at).all.map { |dependency| service_dependency(dependency) }
        output
      end

      def service_dependency(record)
        fields(record, :id, :service_id, :dependency_service_id, :status, :created_at, :updated_at)
      end

      def release(record)
        fields(
          record, :id, :service_id, :build_target_id, :version, :source_type, :source_ref, :artifact_ref,
          :image_digest, :status, :internal_port, :healthcheck_path, :container_name, :route_target,
          :activated_at, :created_at
        )
      end

      def domain(record)
        fields(record, :id, :service_id, :hostname, :route_target, :tls_status, :created_at, :updated_at)
      end

      def job(record)
        fields(record, :id, :type, :status, :progress, :error, :locked_by, :locked_at, :started_at, :finished_at, :created_at)
          .merge(payload: parse_payload(record[:payload_json]))
      end

      def job_event(record)
        fields(record, :id, :job_id, :stream, :message, :created_at)
      end

      def fields(record, *keys)
        keys.each_with_object({}) { |key, output| output[key] = value(record[key]) }
      end

      def value(input)
        input.respond_to?(:iso8601) ? input.utc.iso8601 : input
      end

      def parse_payload(payload_json)
        JSON.parse(payload_json || "{}")
      end
    end
  end
end
