# frozen_string_literal: true

module Valpo
  module Deployments
    class Activator
      def initialize(caddy_reconciler:)
        @caddy_reconciler = caddy_reconciler
      end

      def activate(service:, release:, runtime:, queue:, job_id:, retire: [])
        apply_routes(queue:, job_id:, override_release: release)
        release.activate! unless release.status == "active"
        service.update(status: "running")
        retire.compact.uniq.each { retire_release(it, runtime) unless it.id == release.id }
        release.refresh
      end

      def activate_ready(service:, runtime:, queue:, job_id:)
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
        event(queue, job_id, "Activated release #{release.version} on #{service.name}")
        release.refresh
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

      def event(queue, job_id, message)
        queue.event(job_id, "system", message)
      end
    end
  end
end
