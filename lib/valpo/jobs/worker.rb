# frozen_string_literal: true

require "securerandom"
require "socket"
require "valpo/deployments/orchestrator"
require "valpo/jobs/queue"

module Valpo
  module Jobs
    class SystemCheck
      def call(job, queue:)
        queue.event(job[:id], "stdout", "Valpo worker executed system_check")
      end
    end

    class DeployRegistryImage
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        payload = job.payload
        orchestrator.deploy_registry_image(
          project_id: payload.fetch("project_id"),
          image: payload.fetch("image"),
          internal_port: Integer(payload.fetch("internal_port")),
          healthcheck_path: payload["healthcheck_path"],
          queue: queue,
          job_id: job[:id]
        )
      end

      private

      attr_reader :orchestrator
    end

    class RollbackRelease
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        payload = job.payload
        orchestrator.rollback_project(project_id: payload.fetch("project_id"), queue: queue, job_id: job[:id])
      end

      private

      attr_reader :orchestrator
    end

    class ApplyCaddyConfig
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        orchestrator.apply_caddy_config(queue: queue, job_id: job[:id])
      end

      private

      attr_reader :orchestrator
    end

    class StopProject
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        payload = job.payload
        orchestrator.stop_project(project_id: payload.fetch("project_id"), queue: queue, job_id: job[:id])
      end

      private

      attr_reader :orchestrator
    end

    class RestartProject
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        payload = job.payload
        orchestrator.restart_project(project_id: payload.fetch("project_id"), queue: queue, job_id: job[:id])
      end

      private

      attr_reader :orchestrator
    end

    class DeleteProject
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        payload = job.payload
        orchestrator.delete_project(project_id: payload.fetch("project_id"), queue: queue, job_id: job[:id])
      end

      private

      attr_reader :orchestrator
    end

    class Worker
      DEFAULT_STALE_LOCK_TIMEOUT = 6 * 60 * 60

      def initialize(queue: Valpo::Jobs::Queue.new, handlers: nil, worker_id: nil, poll_interval: 2, stale_lock_timeout: DEFAULT_STALE_LOCK_TIMEOUT, config: Valpo.config || Valpo::Config.load)
        @queue = queue
        @handlers = handlers || self.class.default_handlers(config: config)
        @worker_id = worker_id || default_worker_id
        @poll_interval = poll_interval
        @stale_lock_timeout = stale_lock_timeout
      end

      def self.default_handlers(config:)
        orchestrator = Valpo::Deployments::Orchestrator.new(config: config)
        {
          "system_check" => SystemCheck.new,
          "deploy_registry_image" => DeployRegistryImage.new(orchestrator: orchestrator),
          "rollback_release" => RollbackRelease.new(orchestrator: orchestrator),
          "apply_caddy_config" => ApplyCaddyConfig.new(orchestrator: orchestrator),
          "stop_project" => StopProject.new(orchestrator: orchestrator),
          "restart_project" => RestartProject.new(orchestrator: orchestrator),
          "delete_project" => DeleteProject.new(orchestrator: orchestrator)
        }
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
