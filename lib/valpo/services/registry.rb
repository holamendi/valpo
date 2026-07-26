# frozen_string_literal: true

module Valpo
  module Services
    class Registry
      SECRET_ENV_KEYS = %w[DATABASE_URL PGPASSWORD REDIS_URL REDIS_PASSWORD].freeze
      OPTION_KEYS = %i[version command port internal_port healthcheck healthcheck_path].freeze
      DEFINITIONS = [
        Definitions::Web.new,
        Definitions::Worker.new,
        Definitions::Postgres.new,
        Definitions::Redis.new
      ].to_h { [it.name, it] }.freeze

      class << self
        def definitions
          DEFINITIONS
        end

        def names
          DEFINITIONS.keys
        end

        def fetch(type)
          DEFINITIONS.fetch(normalize_type(type))
        end

        def normalize_type(type)
          normalized = type.to_s.strip.downcase
          raise Valpo::ValidationError, "type is required" if normalized.empty?
          return normalized if DEFINITIONS.key?(normalized)

          raise Valpo::ValidationError,
            "Unsupported service type: #{normalized}. Supported types: #{names.join(", ")}"
        end

        def app_types
          DEFINITIONS.values.select(&:app?).map(&:name).freeze
        end

        def managed_types
          DEFINITIONS.values.select(&:managed?).map(&:name).freeze
        end

        def app_type?(type)
          definition = DEFINITIONS[type.to_s]
          definition&.app? || false
        end

        def managed_type?(type)
          definition = DEFINITIONS[type.to_s]
          definition&.managed? || false
        end

        def normalize_version(type, version)
          definition = fetch(type)
          unless definition.managed?
            raise Valpo::ValidationError, "version is only valid for postgres and redis services"
          end

          normalized = blank_to_nil(version) || definition.default_version
          return normalized if definition.versions.include?(normalized)

          raise Valpo::ValidationError,
            "Unsupported #{definition.name} version: #{normalized}. Supported versions: #{definition.versions.join(", ")}"
        end

        def validate_options!(type:, options:)
          definition = fetch(type)
          supplied = options.keys.map(&:to_sym) & OPTION_KEYS
          invalid = supplied - definition.supported_options
          return definition.name if invalid.empty?

          names = invalid.map { "--#{it.to_s.tr("_", "-")}" }
          raise Valpo::ValidationError,
            "#{names.join(", ")} #{(invalid.length == 1) ? "is" : "are"} not valid for #{definition.name} services"
        end

        def normalize_command(command)
          unless command.is_a?(Array) && command.all? { it.is_a?(String) && !it.empty? }
            raise Valpo::ValidationError, "command must be an array of non-empty strings"
          end

          command
        end

        def managed_config(service)
          Valpo::ManagedServiceConfig[service.id] ||
            raise(Valpo::ValidationError, "Managed configuration missing for #{service.name}")
        end

        def runtime_attributes(service)
          definition = fetch_managed(service.kind)
          runtime_name = "valpo-#{service.id.tr("_", "-")}"
          {
            container_name: runtime_name,
            volume_name: "#{runtime_name}-data",
            internal_host: runtime_name,
            internal_port: definition.internal_port
          }
        end

        def container_environment(service)
          config = managed_config(service)
          fetch_managed(service.kind).container_environment(config.credentials)
        end

        def command(service)
          config = managed_config(service)
          fetch_managed(service.kind).command(config.credentials)
        end

        def readiness_command(service)
          config = managed_config(service)
          fetch_managed(service.kind).readiness_command(config.credentials)
        end

        def volume_path(service)
          fetch_managed(service.kind).volume_path
        end

        def binding_environment(service)
          fetch_managed(service.kind).binding_environment(managed_config(service))
        end

        def secret_env_key?(key)
          SECRET_ENV_KEYS.include?(key.to_s)
        end

        private

        def fetch_managed(type)
          definition = fetch(type)
          return definition if definition.managed?

          raise Valpo::ValidationError, "Unsupported managed service type: #{definition.name}"
        end

        def blank_to_nil(value)
          (value.nil? || value.to_s.strip.empty?) ? nil : value.to_s
        end
      end
    end
  end
end
