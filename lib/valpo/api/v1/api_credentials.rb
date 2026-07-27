# frozen_string_literal: true

module Valpo
  module API
    module V1
      module APICredentials
        class CreateContract < Contract
          json do
            required(:name).filled(:string, format?: NONEMPTY)
            optional(:scopes).array(:string, included_in?: Valpo::APICredential::SCOPES)
          end
        end

        module_function

        def render(credential)
          Fields.call(
            credential,
            :id,
            :name,
            :token_prefix,
            :last_used_at,
            :expires_at,
            :revoked_at,
            :created_at,
            :updated_at
          ).merge(scopes: credential.scopes)
        end
      end
    end
  end
end
