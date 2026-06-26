# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module API
    module Serializers
      module_function

      def project(record)
        fields(record, :id, :name, :type, :status, :created_at, :updated_at)
      end

      def job(record)
        fields(record, :id, :type, :status, :progress, :error, :locked_by, :locked_at, :started_at, :finished_at, :created_at)
          .merge(payload: parse_payload(record[:payload_json]))
      end

      def job_event(record)
        fields(record, :id, :job_id, :stream, :message, :created_at)
      end

      def fields(record, *keys)
        keys.each_with_object({}) do |key, output|
          output[key] = value(record[key])
        end
      end

      def value(input)
        input.respond_to?(:iso8601) ? input.utc.iso8601 : input
      end

      def parse_payload(payload_json)
        JSON.parse(payload_json || "{}")
      end
    end
  end
end
