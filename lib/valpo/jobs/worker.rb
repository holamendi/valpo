# frozen_string_literal: true

require "securerandom"
require "socket"
require "valpo/jobs/queue"

module Valpo
  module Jobs
    class SystemCheck
      def call(job, queue:)
        queue.event(job[:id], "stdout", "Valpo worker executed system_check")
      end
    end

    class Worker
      DEFAULT_STALE_LOCK_TIMEOUT = 6 * 60 * 60
      DEFAULT_HANDLERS = {
        "system_check" => SystemCheck.new
      }.freeze

      def initialize(queue: Valpo::Jobs::Queue.new, handlers: DEFAULT_HANDLERS, worker_id: nil, poll_interval: 2, stale_lock_timeout: DEFAULT_STALE_LOCK_TIMEOUT)
        @queue = queue
        @handlers = handlers
        @worker_id = worker_id || default_worker_id
        @poll_interval = poll_interval
        @stale_lock_timeout = stale_lock_timeout
      end

      def run(once: false)
        loop do
          queue.release_stale_locks(older_than: stale_lock_timeout)
          job = queue.lock_next(worker_id)
          if job
            perform(job)
            return job if once
          elsif once
            return nil
          else
            sleep poll_interval
          end
        end
      end

      private

      attr_reader :queue, :handlers, :worker_id, :poll_interval, :stale_lock_timeout

      def perform(job)
        queue.event(job[:id], "system", "Starting #{job[:type]}")
        handler = handlers[job[:type]]
        raise Valpo::ValidationError, "Unknown job type: #{job[:type]}" unless handler

        handler.call(job, queue: queue)
        if queue.succeed(job[:id], worker_id: worker_id)
          queue.event(job[:id], "system", "Job succeeded")
        end
      rescue StandardError => e
        queue.event(job[:id], "stderr", "#{e.class}: #{e.message}")
        queue.fail(job[:id], e.message, worker_id: worker_id)
      end

      def default_worker_id
        "#{Socket.gethostname}-#{$PROCESS_ID}-#{SecureRandom.hex(4)}"
      end
    end
  end
end
