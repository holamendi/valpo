# frozen_string_literal: true

module Valpo
  module API
    class BadRequest < StandardError
      attr_reader :details

      def initialize(message = "Request validation failed", details: nil)
        super(message)
        @details = details
      end
    end
  end
end
