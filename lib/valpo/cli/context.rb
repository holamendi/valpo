# frozen_string_literal: true

module Valpo
  module CLI
    class Context
      attr_reader :client, :presenter, :resolver, :waiter

      def self.build(api_url:, json:, out:, err:, server: nil)
        client = CLI.sessions.client(api_url:, server:)
        new(
          client:,
          presenter: Presenter.new(out:, err:, json:),
          resolver: ReferenceResolver.new(client:),
          waiter: JobWaiter.new(client:, err:)
        )
      end

      def initialize(client:, presenter:, resolver: nil, waiter: nil)
        @client = client
        @presenter = presenter
        @resolver = resolver || ReferenceResolver.new(client:)
        @waiter = waiter || JobWaiter.new(client:, err: presenter.err)
      end

      def request(method, path, payload = nil, query: nil)
        client.request(method, path, payload, query:)
      rescue Valpo::API::Client::Error => e
        raise OperationalError, e.message
      end

      def service_path(reference, project: nil)
        "/v1/services/#{resolver.service_id(reference, project:)}"
      end

      def finish_operation(response, wait:, timeout:)
        job, nested = operation_job(response)
        return response unless wait && job

        completed = waiter.wait(job.fetch("id"), timeout:)
        nested ? response.merge("job" => completed) : completed
      end

      private

      def operation_job(response)
        return [nil, false] unless response.is_a?(Hash)
        return [response.fetch("job"), true] if response["job"].is_a?(Hash)
        return [response, false] if response["id"].to_s.start_with?("job_") && response.key?("status")

        [nil, false]
      end
    end
  end
end
