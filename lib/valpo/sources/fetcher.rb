# frozen_string_literal: true

module Valpo
  module Sources
    class Fetcher
      def initialize(adapters:)
        @adapters = adapters
      end

      def checkout(source:, destination:, ref: nil)
        adapter = adapters[source.provider]
        raise Valpo::ValidationError, "Unsupported source provider: #{source.provider}" unless adapter

        adapter.checkout(source:, destination:, ref:)
      end

      private

      attr_reader :adapters
    end
  end
end
