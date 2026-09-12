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
      end
    end
  end
end
