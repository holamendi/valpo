# frozen_string_literal: true

module Valpo
  module Services
    module Definitions
      TYPES = {
        "web" => {
          category: :app,
          description: "HTTP application routed through Caddy",
          options: %i[command port healthcheck_path]
        },
        "worker" => {
          category: :app,
          description: "Background process without a public route",
          options: %i[command]
        },
        "postgres" => {
          category: :managed,
          description: "Private managed PostgreSQL database",
          versions: %w[16 17 18],
          default_version: "18",
          port: 5432,
          volume_path: "/var/lib/postgresql"
        },
        "redis" => {
          category: :managed,
          description: "Private managed Redis database",
          versions: %w[7 8],
          default_version: "8",
          port: 6379,
          volume_path: "/data"
        }
      }.freeze
      APP_TYPES = TYPES.select { |_name, definition| definition.fetch(:category) == :app }.keys.freeze
      MANAGED_TYPES = TYPES.select { |_name, definition| definition.fetch(:category) == :managed }.keys.freeze

      module_function

      def normalize_type(type)
        normalized = type.to_s.strip.downcase
        raise Valpo::ValidationError, "type is required" if normalized.empty?
        return normalized if TYPES.key?(normalized)

        raise Valpo::ValidationError, "Unsupported service type: #{normalized}. Supported types: #{TYPES.keys.join(", ")}"
      end

      def app_type?(type)
        APP_TYPES.include?(type.to_s)
      end

      def managed_type?(type)
        MANAGED_TYPES.include?(type.to_s)
      end

      def definition_for(type)
        normalized = normalize_type(type)
        definition = TYPES.fetch(normalized)
        raise Valpo::ValidationError, "Unsupported managed service type: #{normalized}" unless definition.fetch(:category) == :managed

        definition
      end

      def normalize_version(type, version)
        normalized_type = normalize_type(type)
        raise Valpo::ValidationError, "version is only valid for postgres and redis services" unless managed_type?(normalized_type)

        definition = TYPES.fetch(normalized_type)
        normalized = blank_to_nil(version) || definition.fetch(:default_version)
        return normalized if definition.fetch(:versions).include?(normalized)

        raise Valpo::ValidationError,
          "Unsupported #{normalized_type} version: #{normalized}. Supported versions: #{definition.fetch(:versions).join(", ")}"
      end

      def validate_options!(type:, options:)
        normalized_type = normalize_type(type)
        supplied = options.each_with_object({}) do |(key, value), result|
          result[key.to_sym] = value
        end

        if managed_type?(normalized_type)
          reject_options!(normalized_type, supplied, %i[command port internal_port healthcheck healthcheck_path])
        else
          reject_options!(normalized_type, supplied, %i[version])
          reject_options!(normalized_type, supplied, %i[port internal_port healthcheck healthcheck_path]) if normalized_type == "worker"
        end

        normalized_type
      end

      def reject_options!(type, supplied, incompatible)
        invalid = incompatible.select { |key| supplied.key?(key) }
        return if invalid.empty?

        names = invalid.map { |key| "--#{key.to_s.tr("_", "-")}" }
        raise Valpo::ValidationError, "#{names.join(", ")} #{(invalid.length == 1) ? "is" : "are"} not valid for #{type} services"
      end
      private_class_method :reject_options!

      def blank_to_nil(value)
        (value.nil? || value.to_s.strip.empty?) ? nil : value.to_s
      end
      private_class_method :blank_to_nil
    end
  end
end
