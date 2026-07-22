# frozen_string_literal: true

require "securerandom"
require "socket"

module Valpo
  module Jobs
    class Worker
      DEFAULT_STALE_LOCK_TIMEOUT = 6 * 60 * 60

      def initialize(
        queue: Valpo::Jobs::Queue.new,
        handlers: nil,
        worker_id: nil,
        poll_interval: 2,
        stale_lock_timeout: DEFAULT_STALE_LOCK_TIMEOUT,
        config: Valpo.config || Valpo::Config.load
      )
        @queue = queue
        @handlers = handlers || HandlerRegistry.build(config:)
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

        handler.call(job, queue:)
        queue.event(job[:id], "system", "Job succeeded") if queue.succeed(job[:id], worker_id:)
      rescue => e
        queue.event(job[:id], "stderr", "#{e.class}: #{e.message}")
        queue.fail(job[:id], e.message, worker_id:)
      end

      def default_worker_id
        "#{Socket.gethostname}-#{$PROCESS_ID}-#{SecureRandom.hex(4)}"
      end
    end
  end
end
