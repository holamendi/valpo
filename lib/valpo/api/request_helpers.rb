# frozen_string_literal: true

require "json"

module Valpo
  module API
    module RequestHelpers
      private

      def parse_json_body
        body = request.body.read
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        raise Valpo::ValidationError, "Request body must be valid JSON"
      end

      def not_found(message)
        response.status = 404
        {error: "not_found", message: message}
      end

      def required_string(payload, key)
        value = payload[key]
        raise Valpo::ValidationError, "#{key} is required" if value.nil? || value.to_s.strip.empty?

        value
      end

      def required_integer(payload, key, fallback_key: nil)
        value = payload[key]
        value = payload[fallback_key] if value.nil? && fallback_key
        raise Valpo::ValidationError, "#{key} is required" if value.nil? || value.to_s.strip.empty?

        parse_integer(value, key)
      end

      def optional_positive_integer(value, key)
        return nil if value.nil? || value.to_s.strip.empty?

        integer = parse_integer(value, key)
        raise Valpo::ValidationError, "#{key} must be greater than 0" unless integer.positive?

        integer
      end

      def parse_integer(value, key)
        integer = Integer(value)
        if value.is_a?(Numeric) && value != integer
          raise Valpo::ValidationError, "#{key} must be an integer"
        end

        integer
      rescue ArgumentError, TypeError
        raise Valpo::ValidationError, "#{key} must be an integer"
      end

      def validate_port!(value, key)
        raise Valpo::ValidationError, "#{key} must be between 1 and 65535" unless value.between?(1, 65_535)

        value
      end

      def optional_healthcheck_path(value)
        return nil if value.nil? || value.to_s.strip.empty?

        path = value.to_s
        raise Valpo::ValidationError, "healthcheck_path must start with /" unless path.start_with?("/")

        path
      end
    end
  end
end
