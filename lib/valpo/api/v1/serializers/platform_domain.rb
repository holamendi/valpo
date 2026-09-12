# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class PlatformDomain < Serializer
          fields :id, :hostname, :status, :active, :verification_error, :verified_at, :created_at, :updated_at

          def self.render(domain)
            super if domain
          end
        end
      end
    end
  end
end
