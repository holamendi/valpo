# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Jobs
    class Queue
      def enqueue(type, payload = {})
        job = Valpo::Job.create(
          type: type,
          payload_json: JSON.generate(payload)
        )
        event(job.id, "system", "Job queued")
        find(job.id)
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
          updated == 1 ? find(job.id) : nil
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

      def now
        Time.now.utc
      end
    end
  end
end
