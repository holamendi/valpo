# frozen_string_literal: true

module Valpo
  module Deployments
    class PortResolver
      SOURCE_FALLBACK_PORT = 3000

      def resolve(service:, explicit_port:, source_type:, image_metadata:)
        return nil unless service.web?
        return explicit_port if explicit_port

        ports = image_metadata.exposed_tcp_ports
        return ports.first if ports.length == 1
        if ports.length > 1
          raise Valpo::ValidationError, "Image exposes multiple TCP ports (#{ports.join(", ")}); --port is required"
        end
        return SOURCE_FALLBACK_PORT if source_type == "git"

        raise Valpo::ValidationError, "Image does not expose a TCP port; --port is required"
      end
    end
  end
end
