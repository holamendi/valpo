# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class APICredential < Serializer
          fields :id, :name, :token_prefix, :last_used_at, :expires_at, :revoked_at, :created_at, :updated_at

          field(:scopes) { it.scopes }
        end
      end
    end
  end
end
