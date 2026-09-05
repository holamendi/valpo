# frozen_string_literal: true

require "json"
require "digest"
require "time"

module Valpo
  module Jobs
    class Queue
      INTERRUPTED_ERROR = "Interrupted; reconciliation required to resolve job"
      ACTIVE_PROJECT_JOB_STATUSES = %w[queued running].freeze
      DEFAULT_EVENT_LIMIT = 200
      DEFAULT_JOB_LIMIT = 100
      MAX_PAGE_LIMIT = 500
      PROJECT_OPERATION_TYPES = %w[
        delete_project
        apply_project_manifest
        create_source_service
      ].freeze
      SERVICE_OPERATION_TYPES = %w[
        deploy_registry_image
        deploy_source
        rollback_release
        verify_domain
        apply_caddy_config
        provision_service
        bind_service
        unbind_service
        stop_service
        restart_service
        reconcile_service_environment
        update_app_service
        delete_service
      ].freeze
      SUPPORTED_TYPES = (
        %w[system_check repair_system maintain_storage verify_secrets rotate_secrets verify_platform_domain] +
        PROJECT_OPERATION_TYPES +
        SERVICE_OPERATION_TYPES
      ).uniq.freeze

      def self.fingerprint(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def self.canonical(value)
        case value
        when Hash
          value.to_h { |key, item| [key.to_s, canonical(item)] }.sort.to_h
        when Array
          value.map { canonical(it) }
        else
          value
        end
      end

      def initialize(idempotency_key: nil, request_fingerprint: nil)
        @idempotency_key = idempotency_key
        @request_fingerprint = request_fingerprint
      end

      def enqueue(type, payload = {}, idempotency_key: nil, **attributes)
        type = validate_type(type)
        payload = payload.merge(attributes)
        idempotency_key ||= @idempotency_key
        Valpo::Database.connection.transaction(mode: :immediate) do
          fingerprint = fingerprint_for(type, payload)
          find_idempotent(type, idempotency_key, fingerprint:) ||
            create_job(type, payload, idempotency_key:, request_fingerprint: fingerprint)
        end
      end

      def enqueue_unique(type, payload = {}, idempotency_key: nil, **attributes)
        type = validate_type(type)
        payload = payload.merge(attributes)
        idempotency_key ||= @idempotency_key
        Valpo::Database.connection.transaction(mode: :immediate) do
          fingerprint = fingerprint_for(type, payload)
          idempotent = find_idempotent(type, idempotency_key, fingerprint:)
          return idempotent if idempotent

          existing = Valpo::Job.where(type:, status: ACTIVE_PROJECT_JOB_STATUSES).order(:created_at).first
          if existing && idempotency_key
            raise Valpo::ConflictError, "An unrelated #{type} job is already active: #{existing.id}"
          end
          existing || create_job(type, payload, idempotency_key:, request_fingerprint: fingerprint)
        end
      end

      def enqueue_project_operation(type, project_id:, payload: {}, idempotency_key: nil)
        type = validate_type(type)
        idempotency_key ||= @idempotency_key
        project_id = project_id.to_s
        effective_payload = payload.merge(project_id:)
        Valpo::Database.connection.transaction(mode: :immediate) do
          fingerprint = fingerprint_for(type, effective_payload)
          existing = find_idempotent(type, idempotency_key, fingerprint:)
          return existing if existing

          active_job = active_project_job(project_id)
          if active_job
            raise Valpo::ConflictError, "Project already has an active #{active_job.type} job: #{active_job.id}"
          end

          yield if block_given?

          create_job(type, effective_payload, project_id:, idempotency_key:, request_fingerprint: fingerprint)
        end
      end

      def enqueue_manifest_operation(project_name:, manifest:, idempotency_key: nil)
        idempotency_key ||= @idempotency_key
        effective_payload = {manifest:, project_name:}
        Valpo::Database.connection.transaction(mode: :immediate) do
          fingerprint = fingerprint_for("apply_project_manifest", effective_payload)
          existing = find_idempotent("apply_project_manifest", idempotency_key, fingerprint:)
          return existing if existing

          project = Valpo::Project.where(name: project_name).first
          active_job = project && active_project_job(project.id)
          active_job ||= Valpo::Job.where(status: ACTIVE_PROJECT_JOB_STATUSES, type: "apply_project_manifest")
            .where(project_name:)
            .order(:created_at)
            .first
          if active_job
            raise Valpo::ConflictError, "Project already has an active #{active_job.type} job: #{active_job.id}"
          end

          create_job(
            "apply_project_manifest",
            {manifest:, project_name:, project_id: project&.id},
            project_name:,
            project_id: project&.id,
            idempotency_key:,
            request_fingerprint: fingerprint
          )
        end
      end

      def enqueue_service_operation(type, service_id:, payload: {}, idempotency_key: nil)
        type = validate_type(type)
        idempotency_key ||= @idempotency_key
        service_id = service_id.to_s
        project_id = payload[:project_id] || payload["project_id"]
        project_id = project_id.to_s unless project_id.nil?
        effective_payload = payload.merge(service_id:)

        Valpo::Database.connection.transaction(mode: :immediate) do
          fingerprint = fingerprint_for(type, effective_payload)
          existing = find_idempotent(type, idempotency_key, fingerprint:)
          return existing if existing

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

          create_job(
            type,
            effective_payload,
            project_id:,
            service_id:,
            related_service_id:,
            idempotency_key:,
            request_fingerprint: fingerprint
          )
        end
      end

      def active_project_job(project_id, types: PROJECT_OPERATION_TYPES + SERVICE_OPERATION_TYPES)
        project_id = project_id.to_s
        project_name = Valpo::Project[project_id]&.name
        scope = project_name ? Sequel.|({project_id:}, {project_name:}) : {project_id:}
        Valpo::Job.where(status: ACTIVE_PROJECT_JOB_STATUSES, type: types)
          .where(scope)
          .order(:created_at)
          .first
      end

      def active_service_job(service_id, types: SERVICE_OPERATION_TYPES)
        service_id = service_id.to_s
        Valpo::Job.where(status: ACTIVE_PROJECT_JOB_STATUSES, type: types)
          .where(Sequel.|({service_id:}, {related_service_id: service_id}))
          .order(:created_at)
          .first
      end

      def list(limit: DEFAULT_JOB_LIMIT)
        Valpo::Job.order(Sequel.desc(:created_at), Sequel.desc(:id))
          .limit(validate_limit(limit))
          .all
      end

      def find(id)
        Valpo::Job[id]
      end

      def events(job_id, after: nil, limit: DEFAULT_EVENT_LIMIT)
        dataset = Valpo::JobEvent.where(job_id:)
        if after
          cursor = Valpo::JobEvent.where(id: after, job_id:).first
          raise Valpo::ValidationError, "Event cursor does not belong to job" unless cursor

          dataset = dataset.where(
            Sequel.lit(
              "created_at > ? OR (created_at = ? AND id > ?)",
              cursor.created_at,
              cursor.created_at,
              cursor.id
            )
          )
        end
        dataset.order(:created_at, :id).limit(validate_limit(limit)).all
      end

      def lock_next(worker_id)
        Valpo::Database.connection.transaction(mode: :immediate) do
          job = Valpo::Job.where(status: "queued").order(:created_at).first
          return nil unless job

          timestamp = now
          updated = Valpo::Job.transition_dataset!(Valpo::Job.where(id: job.id), from: "queued", to: "running",
            locked_by: worker_id,
            locked_at: timestamp,
            heartbeat_at: timestamp,
            attempt: Sequel[:attempt] + 1,
            started_at: timestamp)
          (updated == 1) ? find(job.id) : nil
        end
      end

      def recover_running_jobs
        Valpo::Database.connection.transaction(mode: :immediate) do
          recovered = 0
          Valpo::Job.where(status: "running").order(:created_at, :id).each do
            if it.checkpoint == "handler_completed"
              updated = Valpo::Job.transition_dataset!(Valpo::Job.where(id: it.id), from: "running", to: "succeeded",
                progress: 100, error: nil, recovery_action: nil, locked_by: nil, locked_at: nil,
                heartbeat_at: nil, finished_at: now)
              message = "Recovered completed handler after worker termination"
            elsif it.recovery_strategy == "compensating"
              updated = Valpo::Job.transition_dataset!(Valpo::Job.where(id: it.id), from: "running", to: "failed",
                error: INTERRUPTED_ERROR, recovery_action: "reconcile", locked_by: nil, locked_at: nil,
                heartbeat_at: nil, finished_at: now)
              message = "Worker terminated during a compensating operation; enqueue reconciliation to resolve it"
            else
              checkpoint = (it.recovery_strategy == "retryable") ? nil : it.checkpoint
              updated = Valpo::Job.transition_dataset!(Valpo::Job.where(id: it.id), from: "running", to: "queued",
                error: nil, recovery_action: "retry", checkpoint:, locked_by: nil, locked_at: nil,
                heartbeat_at: nil, started_at: nil, finished_at: nil)
              message = "Worker terminated; job queued for recovery attempt #{it.attempt.to_i + 1}"
            end
            next unless updated == 1

            event(it.id, "system", message)
            if it.checkpoint == "handler_completed" && (interrupted_job_id = it.payload["interrupted_job_id"])
              resolve_reconciliation(interrupted_job_id, reconciliation_job_id: it.id)
            end
            recovered += 1
          end
          recovered
        end
      end

      alias_method :abandon_running_jobs, :recover_running_jobs

      def checkpoint(job_id, name)
        updated = Valpo::Job.where(id: job_id, status: "running").update(
          checkpoint: name.to_s,
          heartbeat_at: now
        )
        event(job_id, "system", "Checkpoint: #{name}") if updated == 1
        updated == 1
      end

      def retry(job_id)
        Valpo::Database.connection.transaction(mode: :immediate) do
          job = find(job_id) || raise(Valpo::ValidationError, "Job not found")
          raise Valpo::ConflictError, "Job is not failed" unless job.status == "failed"
          raise Valpo::ConflictError, "Job requires reconciliation" if job.recovery_strategy == "compensating"

          assert_scope_available!(job)
          Valpo::Job.transition_dataset!(Valpo::Job.where(id: job.id), from: "failed", to: "queued",
            error: nil, recovery_action: "retry", locked_by: nil, locked_at: nil,
            heartbeat_at: nil, started_at: nil, finished_at: nil)
          event(job.id, "system", "Job manually queued for retry attempt #{job.attempt.to_i + 1}")
          find(job.id)
        end
      end

      def reconcile(job_id)
        Valpo::Database.connection.transaction(mode: :immediate) do
          job = find(job_id) || raise(Valpo::ValidationError, "Job not found")
          actionable = job.status == "failed" && (job.recovery_action == "reconcile" || job.reconciliation_job_id)
          unless actionable
            raise Valpo::ConflictError, "Job does not require reconciliation"
          end

          payload = {interrupted_job_id: job.id}
          key = "reconcile:#{job.id}"
          fingerprint = self.class.fingerprint(type: "repair_system", payload:)
          reconciliation = find_idempotent("repair_system", key, fingerprint:)
          reconciliation = self.retry(reconciliation.id) if reconciliation&.status == "failed"
          reconciliation ||= create_job(
            "repair_system", payload, idempotency_key: key, request_fingerprint: fingerprint
          )
          job.update(reconciliation_job_id: reconciliation.id)
          event(job.id, "system", "Reconciliation job queued: #{reconciliation.id}")
          reconciliation
        end
      end

      def resolve_reconciliation(job_id, reconciliation_job_id:)
        job = find(job_id)
        reconciliation = find(reconciliation_job_id)
        return nil unless job&.reconciliation_job_id == reconciliation_job_id
        return nil unless reconciliation&.status == "succeeded"

        job.update(recovery_action: nil, resolved_at: now)
        event(job.id, "system", "Resolved by reconciliation job #{reconciliation_job_id}")
        job.refresh
      end

      def succeed(job_id, worker_id:, progress: 100)
        updated = Valpo::Job.transition_dataset!(Valpo::Job.where(id: job_id, locked_by: worker_id), from: "running", to: "succeeded",
          progress:,
          error: nil,
          locked_by: nil,
          locked_at: nil,
          heartbeat_at: nil,
          recovery_action: nil,
          finished_at: now)
        return nil unless updated == 1

        find(job_id)
      end

      def fail(job_id, error, worker_id:)
        updated = Valpo::Job.transition_dataset!(Valpo::Job.where(id: job_id, locked_by: worker_id), from: "running", to: "failed",
          error:,
          locked_by: nil,
          locked_at: nil,
          heartbeat_at: nil,
          recovery_action: (find(job_id).recovery_strategy == "compensating") ? "reconcile" : "retry",
          finished_at: now)
        return nil unless updated == 1

        find(job_id)
      end

      def event(job_id, stream, message)
        Valpo::JobEvent.create(
          job_id:,
          stream:,
          message:
        )
      end

      private

      def create_job(type, payload, project_id: nil, project_name: nil, service_id: nil, related_service_id: nil, idempotency_key: nil, request_fingerprint: nil)
        type = validate_type(type)
        project_id ||= payload[:project_id] || payload["project_id"]
        project_name ||= payload[:project_name] || payload["project_name"]
        service_id ||= payload[:service_id] || payload["service_id"]
        related_service_id ||= payload[:dependency_service_id] || payload["dependency_service_id"]
        job = Valpo::Job.create(
          type:,
          payload_json: JSON.generate(payload),
          project_id:,
          project_name:,
          service_id:,
          related_service_id:,
          idempotency_key:,
          request_fingerprint: (request_fingerprint if idempotency_key),
          operation_generation: next_generation(type, project_id:, service_id:),
          recovery_strategy: RecoveryPolicy.fetch(type)
        )
        event(job.id, "system", "Job queued")
        find(job.id)
      end

      def find_idempotent(type, key, fingerprint:)
        return nil if key.nil? || key.to_s.empty?

        job = Valpo::Job.where(idempotency_key: key.to_s).first
        if job && job.type != type
          raise Valpo::ConflictError, "Idempotency key already belongs to #{job.type} job: #{job.id}"
        end
        if job && job.request_fingerprint != fingerprint
          raise Valpo::ConflictError, "Idempotency key does not match the original request for job: #{job.id}"
        end
        job
      end

      def fingerprint_for(type, payload)
        @request_fingerprint || self.class.fingerprint(type:, payload:)
      end

      def next_generation(type, project_id:, service_id:)
        dataset = if service_id
          Valpo::Job.where(service_id: service_id.to_s)
        elsif project_id
          Valpo::Job.where(project_id: project_id.to_s, service_id: nil)
        else
          Valpo::Job.where(type:, project_id: nil, service_id: nil)
        end
        dataset.max(:operation_generation).to_i + 1
      end

      def assert_scope_available!(job)
        conflict = if job.service_id
          active_service_job(job.service_id)
        elsif job.project_id
          active_project_job(job.project_id)
        end
        raise Valpo::ConflictError, "Scope already has an active #{conflict.type} job: #{conflict.id}" if conflict
      end

      def now
        Time.now.utc
      end

      def validate_limit(limit)
        unless limit.is_a?(Integer) && limit.between?(1, MAX_PAGE_LIMIT)
          raise Valpo::ValidationError, "limit must be between 1 and #{MAX_PAGE_LIMIT}"
        end

        limit
      end

      def validate_type(type)
        type = type.to_s
        raise Valpo::ValidationError, "Unsupported job type: #{type}" unless SUPPORTED_TYPES.include?(type)

        type
      end
    end
  end
end
