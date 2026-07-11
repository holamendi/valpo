# frozen_string_literal: true

require "securerandom"
require "socket"

module Valpo
  module Jobs
    class SystemCheck
      def call(job, queue:)
        queue.event(job[:id], "stdout", "Valpo worker executed system_check")
      end
    end

    class RepairSystem
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        @orchestrator.repair_system(queue: queue, job_id: job[:id])
      end
    end

    class DeployRegistryImage
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        payload = job.payload
        @orchestrator.deploy_registry_image(
          service_id: payload.fetch("service_id"), image: payload.fetch("image"),
          internal_port: payload["internal_port"] && Integer(payload["internal_port"]),
          healthcheck_path: payload["healthcheck_path"], queue: queue, job_id: job[:id]
        )
      end
    end

    class AppOperation
      def initialize(orchestrator:, method:)
        @orchestrator = orchestrator
        @method = method
      end

      def call(job, queue:)
        @orchestrator.public_send(@method, service_id: job.payload.fetch("service_id"), queue: queue, job_id: job[:id])
      end
    end

    class ApplyCaddyConfig
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        @orchestrator.apply_caddy_config(queue: queue, job_id: job[:id])
      end
    end

    class DeleteProject
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        @orchestrator.delete_project(project_id: job.payload.fetch("project_id"), queue: queue, job_id: job[:id])
      end
    end

    class ProvisionService
      def initialize(orchestrator:)
        @orchestrator = orchestrator
      end

      def call(job, queue:)
        @orchestrator.provision_service(service_id: job.payload.fetch("service_id"), queue: queue, job_id: job[:id])
      end
    end

    class BindService
      def initialize(orchestrator:, method:)
        @orchestrator = orchestrator
        @method = method
      end

      def call(job, queue:)
        payload = job.payload
        @orchestrator.public_send(
          @method,
          service_id: payload.fetch("service_id"),
          dependency_service_id: payload.fetch("dependency_service_id"),
          queue: queue,
          job_id: job[:id]
        )
      end
    end

    class ServiceOperation
      def initialize(deployment_orchestrator:, managed_orchestrator:, operation:)
        @deployment_orchestrator = deployment_orchestrator
        @managed_orchestrator = managed_orchestrator
        @operation = operation
      end

      def call(job, queue:)
        payload = job.payload
        service = Valpo::Service[payload.fetch("service_id")] || raise(Valpo::ValidationError, "Service not found")
        orchestrator = service.app? ? @deployment_orchestrator : @managed_orchestrator
        method = (service.app? && @operation == :delete_service) ? :delete_app_service : @operation
        arguments = {service_id: service.id, queue: queue, job_id: job[:id]}
        arguments[:force] = payload.fetch("force", false) if @operation == :delete_service
        orchestrator.public_send(method, **arguments)
      end
    end

    class ApplyProjectManifest
      def initialize(reconciler:)
        @reconciler = reconciler
      end

      def call(job, queue:)
        @reconciler.apply(job.payload.fetch("manifest"), queue: queue, job_id: job[:id])
      end
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
        deployment = Valpo::Deployments::Orchestrator.new(config: config)
        managed = Valpo::Services::Orchestrator.new(config: config)
        {
          "system_check" => SystemCheck.new,
          "repair_system" => RepairSystem.new(orchestrator: deployment),
          "deploy_registry_image" => DeployRegistryImage.new(orchestrator: deployment),
          "rollback_release" => AppOperation.new(orchestrator: deployment, method: :rollback_service),
          "apply_caddy_config" => ApplyCaddyConfig.new(orchestrator: deployment),
          "delete_project" => DeleteProject.new(orchestrator: deployment),
          "provision_service" => ProvisionService.new(orchestrator: managed),
          "bind_service" => BindService.new(orchestrator: managed, method: :bind_service),
          "unbind_service" => BindService.new(orchestrator: managed, method: :unbind_service),
          "stop_service" => ServiceOperation.new(deployment_orchestrator: deployment, managed_orchestrator: managed, operation: :stop_service),
          "restart_service" => ServiceOperation.new(deployment_orchestrator: deployment, managed_orchestrator: managed, operation: :restart_service),
          "delete_service" => ServiceOperation.new(deployment_orchestrator: deployment, managed_orchestrator: managed, operation: :delete_service),
          "apply_project_manifest" => ApplyProjectManifest.new(reconciler: Valpo::Manifests::Reconciler.new)
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
        queue.event(job[:id], "system", "Job succeeded") if queue.succeed(job[:id], worker_id: worker_id)
      rescue => e
        queue.event(job[:id], "stderr", "#{e.class}: #{e.message}")
        queue.fail(job[:id], e.message, worker_id: worker_id)
      end

      def default_worker_id
        "#{Socket.gethostname}-#{$PROCESS_ID}-#{SecureRandom.hex(4)}"
      end
    end
  end
end
