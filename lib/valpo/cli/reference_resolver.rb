# frozen_string_literal: true

require "uri"

module Valpo
  module CLI
    class ReferenceResolver
      def initialize(client:)
        @client = client
        @service_ids = {}
      end

      def service_id(reference)
        value = reference.to_s
        return value if Valpo::Identifier.valid?(value, :service)
        raise UsageError, "Invalid service ID: #{value}" if value.start_with?("svc_")

        project, service = split_reference(value)
        @service_ids[value] ||= client.request(
          :get,
          "/projects/#{segment(project)}/services/#{segment(service)}"
        ).fetch("id")
      rescue KeyError
        raise OperationalError, "API response did not include a service ID for #{value}"
      rescue Valpo::API::Client::Error => e
        raise OperationalError, e.message
      end

      private

      attr_reader :client

      def split_reference(value)
        parts = value.split("/", -1)
        return parts if parts.length == 2 && parts.none?(&:empty?)

        raise UsageError, "Service reference must be PROJECT/NAME or a service ID"
      end

      def segment(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
