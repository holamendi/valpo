# frozen_string_literal: true

module Valpo
  module Deployments
    class Activator
      def initialize(caddy_reconciler:)
        @caddy_reconciler = caddy_reconciler
      end

      def activate(service:, release:, runtime:, queue:, job_id:, retire: [], on_failure: nil)
        committed = false
        apply_routes(queue:, job_id:, override_release: release)
        Valpo::Database.connection.transaction do
          release.activate! unless release.status == "active"
          service.update(status: "running")
        end
        committed = true
        retire.compact.uniq.each do
          retire_release_safely(it, runtime, queue:, job_id:) unless it.id == release.id
        end
        release.refresh
      rescue
        unless committed
          compensate_failure(on_failure, queue:, job_id:)
          restore_routes(queue:, job_id:)
        end
        raise
      end

      def activate_ready(service:, runtime:, queue:, job_id:)
        activated = false
        release = Valpo::Release.ready_for_service(service.id)
        unless release&.route_target
          apply_routes(queue:, job_id:)
          return nil
        end

        previous = Valpo::Release.active_for_service(service.id)
        activate(
          service:,
          release:,
          runtime:,
          queue:,
          job_id:,
          retire: [previous]
        )
        activated = true
        event(queue, job_id, "Activated release #{release.version} on #{service.name}")
        release.refresh
      rescue
        cleanup_candidate_safely(release, runtime, queue:, job_id:) unless activated
        raise
      end

      def apply_routes(queue:, job_id:, **options)
        caddy_reconciler.apply(queue:, job_id:, **options)
      end

      def retire_release(release, runtime)
        return unless release&.container_name

        runtime.stop_container(release.container_name, ignore_missing: true)
        release.update(container_name: nil, route_target: nil)
      end

      private

      attr_reader :caddy_reconciler

      def retire_release_safely(release, runtime, queue:, job_id:)
        retire_release(release, runtime)
      rescue => e
        event(
          queue,
          job_id,
          "Could not retire release #{release.version}: #{e.message}",
          stream: "stderr"
        )
      end

      def cleanup_candidate_safely(release, runtime, queue:, job_id:)
        return unless release&.container_name

        runtime.stop_container(release.container_name, ignore_missing: true)
        release.update(container_name: nil, route_target: nil)
      rescue => e
        event(
          queue,
          job_id,
          "Could not remove failed activation candidate #{release.container_name}: #{e.message}",
          stream: "stderr"
        )
      end

      def compensate_failure(callback, queue:, job_id:)
        callback&.call
      rescue => e
        event(queue, job_id, "Could not restore activation state: #{e.message}", stream: "stderr")
      end

      def restore_routes(queue:, job_id:)
        apply_routes(queue:, job_id:)
      rescue => e
        event(queue, job_id, "Could not restore Caddy config: #{e.message}", stream: "stderr")
      end

      def event(queue, job_id, message, stream: "system")
        queue.event(job_id, stream, message)
      end
    end
  end
end
