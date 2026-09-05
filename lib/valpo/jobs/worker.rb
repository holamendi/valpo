# frozen_string_literal: true

require "securerandom"
require "socket"

module Valpo
  module Jobs
    class Worker
      STORAGE_MAINTENANCE_TRIGGER_TYPES = %w[
        create_source_service
        deploy_source
        update_app_service
      ].freeze

      def initialize(
        queue: Valpo::Jobs::Queue.new,
        handlers: nil,
        worker_id: nil,
        poll_interval: 2,
        config: Valpo.config || Valpo::Config.load,
        worker_lock: nil,
        sleeper: -> { sleep(it) },
        err: $stderr
      )
        @queue = queue
        @handlers = handlers || HandlerRegistry.build(config:)
        @worker_id = worker_id || default_worker_id
        @poll_interval = poll_interval
        @worker_lock = worker_lock || WorkerLock.new(database_path: config.database_path)
        @sleeper = sleeper
        @err = err
        @stop_requested = false
      end

      def run(once: false)
        worker_lock.synchronize do
          queue.recover_running_jobs
          loop do
            return nil if stopping?

            job = queue.lock_next(worker_id)
            if job
              perform(job)
              return job if once
            elsif once
              return nil
            else
              sleeper.call(poll_interval)
            end
          end
        end
      end

      def stop
        @stop_requested = true
      end

      private

      attr_reader :queue, :handlers, :worker_id, :poll_interval, :worker_lock, :sleeper, :err

      def stopping?
        @stop_requested
      end

      def perform(job)
        queue.event(job[:id], "system", "Starting #{job[:type]}")
        queue.checkpoint(job[:id], "handler_started")
        handler = handlers[job[:type]]
        raise Valpo::ValidationError, "Unknown job type: #{job[:type]}" unless handler

        handler.call(job, queue:)
        queue.checkpoint(job[:id], "handler_completed")
        queue.event(job[:id], "system", "Job succeeded") if queue.succeed(job[:id], worker_id:)
      rescue => e
        queue.event(job[:id], "stderr", "#{e.class}: #{e.message}")
        queue.fail(job[:id], e.message, worker_id:)
        err.puts "[valpo-worker] job=#{job[:id]} type=#{job[:type]} failed: #{e.class}: #{e.message}"
        Array(e.backtrace).each { err.puts it }
      ensure
        schedule_storage_maintenance(job)
      end

      def schedule_storage_maintenance(job)
        return unless STORAGE_MAINTENANCE_TRIGGER_TYPES.include?(job[:type])

        queue.enqueue_unique("maintain_storage")
      rescue => e
        err.puts "[valpo-worker] could not schedule storage maintenance: #{e.class}: #{e.message}"
      end

      def default_worker_id
        "#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}"
      end
    end
  end
end
