# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class ServiceDependency < Serializer
          fields :id, :service_id, :dependency_service_id, :status, :created_at, :updated_at
        end
      end
    end
  end
end
