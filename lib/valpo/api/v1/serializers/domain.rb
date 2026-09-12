# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class Domain < Serializer
          fields :id, :service_id, :platform_domain_id, :hostname, :kind, :status,
            :verification_error, :verified_at, :route_target, :created_at, :updated_at
        end
      end
    end
  end
end
