# frozen_string_literal: true

require "valpo"
require "valpo/deployments/command_output"
require "valpo/models/domain"
require "valpo/models/project"
require "valpo/models/release"

module Valpo
  module Deployments
    class RouteProjector
      include CommandOutput

      def initialize(caddy:, queue: nil, job_id: nil)
        @caddy = caddy
        @queue = queue
        @job_id = job_id
      end

      def apply(override_release: nil, exclude_project_id: nil)
        routes, route_targets = routes_and_targets(
          override_release: override_release,
          exclude_project_id: exclude_project_id
        )
        event("system", "Applying Caddy config")
        caddy.write_config(routes)
        execute_command(caddy, caddy.reload_command, failure_message: "Caddy reload failed")

        route_targets.each do |domain_id, route_target|
          Valpo::Domain.where(id: domain_id).update(route_target: route_target)
        end
      end

      private

      attr_reader :caddy, :queue, :job_id

      def routes_and_targets(override_release:, exclude_project_id:)
        routes = []
        route_targets = {}
        excluded_project_id = exclude_project_id&.to_s

        Valpo::Domain.order(:hostname).each do |domain|
          if excluded_project_id == domain.project_id.to_s
            route_targets[domain.id] = nil
            next
          end

          project = Valpo::Project[domain.project_id]
          release = (override_release&.project_id == domain.project_id) ? override_release : Valpo::Release.active_for_project(domain.project_id)

          if project.nil? || project.status == "stopped" || release&.route_target.nil?
            route_targets[domain.id] = nil
            next
          end

          routes << {hostname: domain.hostname, kind: "container", upstream: release.route_target}
          route_targets[domain.id] = release.route_target
        end

        [routes, route_targets]
      end
    end
  end
end
