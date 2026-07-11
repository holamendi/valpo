# frozen_string_literal: true

module Valpo
  module Deployments
    class RouteProjector
      include CommandOutput

      def initialize(caddy:, queue: nil, job_id: nil)
        @caddy = caddy
        @queue = queue
        @job_id = job_id
      end

      def apply(override_release: nil, exclude_service_id: nil)
        routes, targets = routes_and_targets(override_release: override_release, exclude_service_id: exclude_service_id)
        event("system", "Applying Caddy config")
        caddy.write_config(routes)
        execute_command(caddy, caddy.reload_command, failure_message: "Caddy reload failed")
        targets.each { |domain_id, target| Valpo::Domain.where(id: domain_id).update(route_target: target) }
      end

      private

      attr_reader :caddy, :queue, :job_id

      def routes_and_targets(override_release:, exclude_service_id:)
        routes = []
        targets = {}
        Valpo::Domain.order(:hostname).each do |domain|
          service = Valpo::Service[domain.service_id]
          release = if override_release&.service_id == domain.service_id
            override_release
          else
            Valpo::Release.active_for_service(domain.service_id)
          end

          if exclude_service_id.to_s == domain.service_id.to_s || !service&.web? || service.status == "stopped" || release&.route_target.nil?
            targets[domain.id] = nil
            next
          end

          routes << {hostname: domain.hostname, kind: "container", upstream: release.route_target}
          targets[domain.id] = release.route_target
        end
        [routes, targets]
      end
    end
  end
end
