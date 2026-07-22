# frozen_string_literal: true

module Valpo
  module Caddy
    class Reconciler
      def initialize(caddy:)
        @caddy = caddy
      end

      def apply(queue: nil, job_id: nil, override_release: nil, exclude_service_id: nil, extra_routes: [])
        routes, targets = routes_and_targets(
          override_release:,
          exclude_service_id:
        )
        routes.concat(extra_routes)
        event(queue, job_id, "system", "Applying Caddy config")
        caddy.write_config(routes)
        result = caddy.execute(caddy.reload_command)
        emit_output(queue, job_id, result)
        raise_command_error(result) unless result.fetch(:success)
        targets.each { |domain_id, target| Valpo::Domain.where(id: domain_id).update(route_target: target) }
        true
      end

      private

      attr_reader :caddy

      def routes_and_targets(override_release:, exclude_service_id:)
        routes = []
        targets = {}
        Valpo::Domain.order(:hostname).each do
          service = Valpo::Service[it.service_id]
          release = if override_release&.service_id == it.service_id
            override_release
          else
            Valpo::Release.active_for_service(it.service_id)
          end

          if !it.verified? || exclude_service_id.to_s == it.service_id.to_s ||
              !service&.web? || service.status == "stopped" || release&.route_target.nil?
            targets[it.id] = nil
            next
          end

          routes << {hostname: it.hostname, kind: "container", upstream: release.route_target}
          targets[it.id] = release.route_target
        end
        [routes, targets]
      end

      def emit_output(queue, job_id, result)
        stdout = result.fetch(:stdout).to_s.strip
        stderr = result.fetch(:stderr).to_s.strip
        event(queue, job_id, "stdout", stdout) unless stdout.empty?
        event(queue, job_id, "stderr", stderr) unless stderr.empty?
      end

      def event(queue, job_id, stream, message)
        queue&.event(job_id, stream, message) if job_id
      end

      def raise_command_error(result)
        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "Caddy reload failed: #{detail}"
      end
    end
  end
end
