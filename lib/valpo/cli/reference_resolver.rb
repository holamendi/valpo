# frozen_string_literal: true

require "uri"

module Valpo
  module CLI
    class ReferenceResolver
      def initialize(client:)
        @client = client
        @service_ids = {}
      end

      def service_id(reference, project: nil)
        value = reference.to_s
        return value if Valpo::Identifier.valid?(value, :service)
        raise UsageError, "Invalid service ID: #{value}" if value.start_with?("svc_")

        service = service_name(value)
        project = required_project(project)
        @service_ids[[project, service]] ||= client.request(
          :get,
          "/v1/projects/#{segment(project)}/services/#{segment(service)}"
        ).fetch("id")
      rescue KeyError
        raise OperationalError, "API response did not include a service ID for #{value}"
      rescue Valpo::API::Client::Error => e
        raise OperationalError, e.message
      end

      private

      attr_reader :client

      def service_name(value)
        raise UsageError, "Service names must not contain /; pass the project with --project" if value.include?("/")
        raise UsageError, "Service name is required" if value.empty?

        value
      end

      def required_project(value)
        project = value.to_s
        raise UsageError, "--project is required when using a service name" if project.empty?

        project
      end

      def segment(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
