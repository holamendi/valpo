# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Jobs
    class Queue
      ACTIVE_PROJECT_JOB_STATUSES = %w[queued running].freeze
      PROJECT_OPERATION_TYPES = %w[
        delete_project
        apply_project_manifest
        create_source_service
      ].freeze
      SERVICE_OPERATION_TYPES = %w[
        deploy_registry_image
        deploy_source
        rollback_release
        apply_caddy_config
        provision_service
        bind_service
        unbind_service
        stop_service
        restart_service
        update_app_service
        delete_service
      ].freeze

      def enqueue(type, payload = {})
        Valpo::Database.connection.transaction(mode: :immediate) do
          create_job(type, payload)
        end
      end

      def enqueue_project_operation(type, project_id:, payload: {})
        project_id = project_id.to_s
        Valpo::Database.connection.transaction(mode: :immediate) do
          active_job = active_project_job(project_id)
          if active_job
            raise Valpo::ConflictError, "Project already has an active #{active_job.type} job: #{active_job.id}"
          end

          yield if block_given?

          create_job(type, payload.merge(project_id: project_id))
        end
      end

      def enqueue_manifest_operation(project_name:, manifest:)
        Valpo::Database.connection.transaction(mode: :immediate) do
          project = Valpo::Project.where(name: project_name).first
          active_job = project && active_project_job(project.id)
          active_job ||= Valpo::Job.where(status: ACTIVE_PROJECT_JOB_STATUSES, type: "apply_project_manifest")
            .order(:created_at)
            .all
            .find { |job| job.payload.dig("manifest", "project", "name") == project_name }
          if active_job
            raise Valpo::ConflictError, "Project already has an active #{active_job.type} job: #{active_job.id}"
          end

          create_job(
            "apply_project_manifest",
            manifest: manifest,
            project_name: project_name,
            project_id: project&.id
          )
        end
      end

      def enqueue_service_operation(type, service_id:, payload: {})
        service_id = service_id.to_s
        project_id = payload[:project_id] || payload["project_id"]
        project_id = project_id.to_s unless project_id.nil?

        Valpo::Database.connection.transaction(mode: :immediate) do
          active_service_job = active_service_job(service_id)
          if active_service_job
            raise Valpo::ConflictError, "Service already has an active #{active_service_job.type} job: #{active_service_job.id}"
          end

          related_service_id = payload[:dependency_service_id] || payload["dependency_service_id"]
          if related_service_id && (related_job = active_service_job(related_service_id))
            raise Valpo::ConflictError, "Service already has an active #{related_job.type} job: #{related_job.id}"
          end

          if project_id && (project_job = active_project_job(project_id, types: PROJECT_OPERATION_TYPES))
            raise Valpo::ConflictError, "Project already has an active #{project_job.type} job: #{project_job.id}"
          end

          yield if block_given?

          create_job(type, payload.merge(service_id: service_id))
        end
      end

      def active_project_job(project_id, types: PROJECT_OPERATION_TYPES + SERVICE_OPERATION_TYPES)
        project_id = project_id.to_s
        project_name = Valpo::Project[project_id]&.name
        Valpo::Job.where(status: ACTIVE_PROJECT_JOB_STATUSES, type: types)
          .order(:created_at)
          .all
          .find do |job|
            payload = job.payload
            payload["project_id"].to_s == project_id ||
              (project_name && (payload["project_name"] == project_name || payload.dig("manifest", "project", "name") == project_name))
          end
      end

      def active_service_job(service_id, types: SERVICE_OPERATION_TYPES)
        service_id = service_id.to_s
        Valpo::Job.where(status: ACTIVE_PROJECT_JOB_STATUSES, type: types)
          .order(:created_at)
          .all
          .find do |job|
            payload = job.payload
            payload["service_id"].to_s == service_id || payload["dependency_service_id"].to_s == service_id
          end
      end

      def list
        Valpo::Job.reverse_order(:created_at).all
      end

      def find(id)
        Valpo::Job[id]
      end

      def events(job_id)
        Valpo::JobEvent.where(job_id: job_id).order(:created_at).all
      end

      def lock_next(worker_id)
        Valpo::Database.connection.transaction(mode: :immediate) do
          job = Valpo::Job.where(status: "queued").order(:created_at).first
          return nil unless job

          timestamp = now
          updated = Valpo::Job.where(id: job.id, status: "queued").update(
            status: "running",
            locked_by: worker_id,
            locked_at: timestamp,
            started_at: timestamp
          )
          (updated == 1) ? find(job.id) : nil
        end
      end

      def release_stale_locks(older_than:)
        cutoff = now - older_than
        Valpo::Job.where(status: "running")
          .where { locked_at < cutoff }
          .update(status: "queued", locked_by: nil, locked_at: nil, started_at: nil)
      end

      def succeed(job_id, worker_id:, progress: 100)
        updated = Valpo::Job.where(id: job_id, status: "running", locked_by: worker_id).update(
          status: "succeeded",
          progress: progress,
          error: nil,
          locked_by: nil,
          locked_at: nil,
          finished_at: now
        )
        return nil unless updated == 1

        find(job_id)
      end

      def fail(job_id, error, worker_id:)
        updated = Valpo::Job.where(id: job_id, status: "running", locked_by: worker_id).update(
          status: "failed",
          error: error,
          locked_by: nil,
          locked_at: nil,
          finished_at: now
        )
        return nil unless updated == 1

        find(job_id)
      end

      def event(job_id, stream, message)
        Valpo::JobEvent.create(
          job_id: job_id,
          stream: stream,
          message: message
        )
      end

      private

      def create_job(type, payload)
        job = Valpo::Job.create(
          type: type,
          payload_json: JSON.generate(payload)
        )
        event(job.id, "system", "Job queued")
        find(job.id)
      end

      def now
        Time.now.utc
      end
    end
  end
end
