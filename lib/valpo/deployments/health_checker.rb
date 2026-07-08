# frozen_string_literal: true

require "net/http"
require "socket"
require "time"
require "valpo"

module Valpo
  module Deployments
    class HealthChecker
      RETRY_INTERVAL = 0.25

      def wait(route_target:, path:, timeout:)
        deadline = Time.now + timeout
        last_error = nil

        loop do
          begin
            return true if healthy?(route_target: route_target, path: path)
          rescue => e
            last_error = e
          end

          break if Time.now >= deadline

          sleep RETRY_INTERVAL
        end

        detail = last_error ? ": #{last_error.message}" : ""
        raise Valpo::ValidationError, "Health check failed for #{route_target}#{detail}"
      end

      private

      def healthy?(route_target:, path:)
        host, port = route_target.split(":", 2)
        port = Integer(port)

        if path && !path.empty?
          response = Net::HTTP.start(host, port, open_timeout: 1, read_timeout: 1) do |http|
            http.get(path)
          end
          response.code.to_i.between?(200, 399)
        else
          socket = TCPSocket.new(host, port)
          socket.close
          true
        end
      end
    end
  end
end
