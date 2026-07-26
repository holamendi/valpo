# frozen_string_literal: true

require "net/http"
require "time"

module Valpo
  module Deployments
    class HealthChecker
      RETRY_INTERVAL = 0.25

      def initialize(
        http: Net::HTTP,
        sleeper: Kernel,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      )
        @http = http
        @sleeper = sleeper
        @clock = clock
      end

      def wait(route_target:, path:, timeout:)
        deadline = clock.call + timeout
        last_error = nil

        loop do
          begin
            return true if healthy?(route_target:, path:)
          rescue => e
            last_error = e
          end

          break if clock.call >= deadline

          sleeper.sleep(RETRY_INTERVAL)
        end

        detail = last_error ? ": #{last_error.message}" : ""
        raise Valpo::ValidationError, "Health check failed for #{route_target}#{detail}"
      end

      private

      attr_reader :http, :sleeper, :clock

      def healthy?(route_target:, path:)
        host, port = route_target.split(":", 2)
        port = Integer(port)

        response = http.start(host, port, open_timeout: 1, read_timeout: 1) do
          it.get(path || "/")
        end
        return true if path.nil? || path.empty?

        response.code.to_i.between?(200, 399)
      end
    end
  end
end
