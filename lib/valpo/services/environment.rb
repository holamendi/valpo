# frozen_string_literal: true

module Valpo
  module Services
    module Environment
      RESERVED_KEYS = %w[PORT].freeze

      module_function

      def raw_for_service(service_id)
        entries_for_service(service_id, reveal: true).each_with_object({}) do |entry, env|
          name = entry.fetch(:name)
          raise Valpo::ConflictError, "Environment variable is configured by multiple sources: #{name}" if env.key?(name)

          env[name] = entry.fetch(:value)
        end
      end

      def entries_for_service(service_id, reveal:)
        custom_entries(service_id, reveal:) + dependency_entries(service_id, reveal:)
      end

      def custom_entries(service_id, reveal:)
        Valpo::ServiceEnvironmentVariable.where(service_id:).order(:name).map do
          redacted = it.sensitive && !reveal
          {
            name: it.name,
            value: redacted ? "********" : it.value,
            redacted:,
            sensitive: it.sensitive,
            origin: "service",
            environment_variable_id: it.id,
            service_id: nil,
            service_name: nil,
            service_type: nil,
            dependency_id: nil
          }
        end
      end

      def dependency_entries(service_id, reveal:)
        Valpo::ServiceDependency.where(service_id:, status: "active").order(:created_at).flat_map do
          managed = Valpo::Service[it.dependency_service_id]
          next [] unless managed

          dependency_id = it.id
          Registry.binding_environment(managed).sort.map do |name, value|
            redacted = !reveal && Registry.secret_env_key?(name)
            {
              name:,
              value: redacted ? "********" : value,
              redacted:,
              sensitive: Registry.secret_env_key?(name),
              origin: "managed",
              environment_variable_id: nil,
              service_id: managed.id,
              service_name: managed.name,
              service_type: managed.kind,
              dependency_id:
            }
          end
        end
      end

      def conflicting_keys(service_id:, dependency_service_id:, env:)
        dependency_keys = Valpo::ServiceDependency
          .where(service_id:, status: "active")
          .exclude(dependency_service_id:)
          .all
          .flat_map do
            managed = Valpo::Service[it.dependency_service_id]
            managed ? Registry.binding_environment(managed).keys : []
          end
        custom_keys = Valpo::ServiceEnvironmentVariable.where(service_id:).select_map(:name)
        (dependency_keys + custom_keys).uniq & env.keys
      end

      def managed_keys_for_service(service_id)
        Valpo::ServiceDependency.where(service_id:, status: "active").all.flat_map do
          managed = Valpo::Service[it.dependency_service_id]
          managed ? Registry.binding_environment(managed).keys : []
        end.uniq
      end
    end
  end
end
