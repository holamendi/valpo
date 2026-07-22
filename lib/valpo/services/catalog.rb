# frozen_string_literal: true

require "json"
require "securerandom"

module Valpo
  module Services
    module Catalog
      SECRET_ENV_KEYS = %w[DATABASE_URL PGPASSWORD REDIS_URL REDIS_PASSWORD].freeze

      module_function

      def create_service(project_id:, name:, type:, version: nil, command: [], internal_port: nil, healthcheck_path: nil, build_target_id: nil)
        normalized_type = normalize_type(type)
        validate_values!(
          type: normalized_type,
          version: version,
          command: command,
          internal_port: internal_port,
          healthcheck_path: healthcheck_path
        )
        normalized_command = normalize_command(command)
        Valpo::Database.connection.transaction do
          service = Valpo::Service.create(
            project_id: project_id,
            name: name,
            kind: normalized_type,
            status: managed_type?(normalized_type) ? "provisioning" : "created"
          )
          if managed_type?(normalized_type)
            Valpo::ManagedServiceConfig.create(managed_attributes(service, version: version))
          else
            Valpo::AppServiceConfig.create(
              service_id: service.id,
              build_target_id: build_target_id,
              command_json: JSON.generate(normalized_command),
              internal_port: internal_port,
              healthcheck_path: blank_to_nil(healthcheck_path)
            )
            Valpo::Domains::Configuration.reconcile_service(service) if normalized_type == "web"
          end
          service.refresh
        end
      end

      def managed_attributes(service, version: nil)
        normalized_version = normalize_version(service.kind, version)
        {
          service_id: service.id,
          version: normalized_version,
          image: image_for(service.kind, normalized_version),
          plan: "starter",
          credentials_json: JSON.generate(credentials_for(service.kind))
        }
      end

      def runtime_attributes(service)
        definition = definition_for(service.kind)
        {
          container_name: "valpo-#{service.id}",
          volume_name: "valpo-#{service.id}-data",
          internal_host: "valpo-#{service.id}",
          internal_port: definition.fetch(:port)
        }
      end

      def managed_config(service)
        Valpo::ManagedServiceConfig[service.id] || raise(Valpo::ValidationError, "Managed configuration missing for #{service.name}")
      end

      def container_env(service)
        credentials = managed_config(service).credentials
        case service.kind
        when "postgres"
          {
            "POSTGRES_DB" => credentials.fetch("database"),
            "POSTGRES_USER" => credentials.fetch("username"),
            "POSTGRES_PASSWORD" => credentials.fetch("password")
          }
        when "redis" then {}
        else raise Valpo::ValidationError, "Unsupported managed service type: #{service.kind}"
        end
      end

      def command_args(service)
        case service.kind
        when "postgres" then []
        when "redis" then ["redis-server", "--appendonly", "yes", "--requirepass", managed_config(service).credentials.fetch("password")]
        else raise Valpo::ValidationError, "Unsupported managed service type: #{service.kind}"
        end
      end

      def readiness_args(service)
        credentials = managed_config(service).credentials
        case service.kind
        when "postgres" then ["pg_isready", "-U", credentials.fetch("username"), "-d", credentials.fetch("database")]
        when "redis" then ["redis-cli", "-a", credentials.fetch("password"), "PING"]
        else raise Valpo::ValidationError, "Unsupported managed service type: #{service.kind}"
        end
      end

      def volume_path(service)
        definition_for(service.kind).fetch(:volume_path)
      end

      def binding_env(service)
        config = managed_config(service)
        credentials = config.credentials
        host = config.internal_host || config.container_name
        port = config.internal_port
        case service.kind
        when "postgres"
          database = credentials.fetch("database")
          username = credentials.fetch("username")
          password = credentials.fetch("password")
          {
            "DATABASE_URL" => "postgres://#{username}:#{password}@#{host}:#{port}/#{database}",
            "PGHOST" => host,
            "PGPORT" => port.to_s,
            "PGDATABASE" => database,
            "PGUSER" => username,
            "PGPASSWORD" => password
          }
        when "redis"
          password = credentials.fetch("password")
          {
            "REDIS_URL" => "redis://:#{password}@#{host}:#{port}/0",
            "REDIS_HOST" => host,
            "REDIS_PORT" => port.to_s,
            "REDIS_PASSWORD" => password
          }
        else
          raise Valpo::ValidationError, "Unsupported managed service type: #{service.kind}"
        end
      end

      def secret_env_key?(key)
        SECRET_ENV_KEYS.include?(key.to_s)
      end

      def managed_type?(type)
        Definitions.managed_type?(type)
      end

      def normalize_command(command)
        unless command.is_a?(Array) && command.all? { |entry| entry.is_a?(String) && !entry.empty? }
          raise Valpo::ValidationError, "command must be an array of non-empty strings"
        end

        command
      end

      def app_type?(type)
        Definitions.app_type?(type)
      end

      def normalize_type(type)
        Definitions.normalize_type(type)
      end

      def normalize_version(type, version)
        Definitions.normalize_version(type, version)
      end

      def definition_for(type)
        Definitions.definition_for(type)
      end

      def validate_values!(type:, version:, command:, internal_port:, healthcheck_path:)
        if managed_type?(type)
          raise Valpo::ValidationError, "command is not valid for #{type} services" unless command.nil? || command.empty?
          raise Valpo::ValidationError, "port is not valid for #{type} services" unless internal_port.nil?
          raise Valpo::ValidationError, "healthcheck_path is not valid for #{type} services" unless blank_to_nil(healthcheck_path).nil?
        elsif version
          raise Valpo::ValidationError, "version is only valid for postgres and redis services"
        elsif type == "worker"
          raise Valpo::ValidationError, "port is only valid for web services" unless internal_port.nil?
          raise Valpo::ValidationError, "healthcheck_path is only valid for web services" unless blank_to_nil(healthcheck_path).nil?
        end
      end
      private_class_method :validate_values!

      def image_for(type, version)
        "#{type}:#{version}-alpine"
      end

      def credentials_for(type)
        case type
        when "postgres"
          {
            "database" => "valpo_#{SecureRandom.hex(6)}",
            "username" => "valpo_#{SecureRandom.hex(6)}",
            "password" => SecureRandom.urlsafe_base64(32)
          }
        when "redis" then {"password" => SecureRandom.urlsafe_base64(32)}
        else raise Valpo::ValidationError, "Unsupported managed service type: #{type}"
        end
      end

      def blank_to_nil(value)
        (value.nil? || value.to_s.empty?) ? nil : value.to_s
      end
    end
  end
end
