# frozen_string_literal: true

module Valpo
  module Services
    module Environment
      module_function

      def raw_for_service(service_id)
        entries_for_service(service_id, reveal: true).each_with_object({}) do |entry, env|
          env[entry.fetch(:name)] = entry.fetch(:value)
        end
      end

      def entries_for_service(service_id, reveal:)
        Valpo::ServiceDependency.where(service_id:, status: "active").order(:created_at).flat_map do
          managed = Valpo::Service[it.dependency_service_id]
          next [] unless managed

          dependency_id = it.id
          it.env.sort.map do |name, value|
            redacted = !reveal && Registry.secret_env_key?(name)
            {
              name:,
              value: redacted ? "********" : value,
              redacted:,
              service_id: managed.id,
              service_name: managed.name,
              service_type: managed.kind,
              dependency_id:
            }
          end
        end
      end

      def conflicting_keys(service_id:, dependency_service_id:, env:)
        existing_keys = Valpo::ServiceDependency
          .where(service_id:, status: "active")
          .exclude(dependency_service_id:)
          .all
          .flat_map { it.env.keys }
        existing_keys & env.keys
      end
    end
  end
end
