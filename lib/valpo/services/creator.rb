# frozen_string_literal: true

require "json"

module Valpo
  module Services
    class Creator
      def self.call(**attributes)
        new.call(**attributes)
      end

      def call(
        project_id:,
        name:,
        type:,
        version: nil,
        command: [],
        internal_port: nil,
        healthcheck_path: nil,
        build_target_id: nil
      )
        normalized_type = Registry.normalize_type(type)
        Registry.validate_options!(
          type: normalized_type,
          options: supplied_options(
            version:,
            command:,
            internal_port:,
            healthcheck_path:
          )
        )
        normalized_command = Registry.normalize_command(command)

        Valpo::Database.connection.transaction do
          service = Valpo::Service.create(
            project_id:,
            name:,
            kind: normalized_type,
            status: Registry.managed_type?(normalized_type) ? "provisioning" : "created"
          )
          if service.managed?
            create_managed_config(service, version:)
          else
            create_app_config(
              service,
              build_target_id:,
              command: normalized_command,
              internal_port:,
              healthcheck_path:
            )
          end
          service.refresh
        end
      end

      private

      def create_managed_config(service, version:)
        definition = Registry.fetch(service.kind)
        normalized_version = Registry.normalize_version(service.kind, version)
        config = Valpo::ManagedServiceConfig.new(
          service_id: service.id,
          version: normalized_version,
          image: definition.image(normalized_version)
        )
        config.credentials = definition.credentials
        config.save
      end

      def create_app_config(service, build_target_id:, command:, internal_port:, healthcheck_path:)
        Valpo::AppServiceConfig.create(
          service_id: service.id,
          build_target_id:,
          command_json: JSON.generate(command),
          internal_port:,
          healthcheck_path: blank_to_nil(healthcheck_path)
        )
        Valpo::Domains::Configuration.reconcile_service(service) if service.web?
      end

      def supplied_options(version:, command:, internal_port:, healthcheck_path:)
        options = {}
        options[:version] = version unless version.nil?
        options[:command] = command unless command.nil? || command.empty?
        options[:internal_port] = internal_port unless internal_port.nil?
        options[:healthcheck_path] = healthcheck_path unless blank_to_nil(healthcheck_path).nil?
        options
      end

      def blank_to_nil(value)
        (value.nil? || value.to_s.empty?) ? nil : value.to_s
      end
    end
  end
end
