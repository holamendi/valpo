# frozen_string_literal: true

module Valpo
  module API
    module V1
      module GitHub
        class SetupQueryContract < Contract
          params do
            required(:token).filled(:string, format?: NONEMPTY)
          end
        end

        class CreateSetupContract < Contract
          json do
            optional(:organization).filled(:string, format?: NONEMPTY)
          end
        end

        class StorePersonalAccessTokenContract < Contract
          json do
            required(:token).filled(:string, format?: NONEMPTY)
          end
        end

        class CallbackQueryContract < Contract
          params do
            required(:code).filled(:string, format?: NONEMPTY)
            required(:state).filled(:string, format?: NONEMPTY)
          end
        end

        class InstallationQueryContract < Contract
          params do
            required(:installation_id).filled(:integer, gt?: 0)
            optional(:setup_action).filled(:string, included_in?: %w[install update])
          end
        end
      end
    end
  end
end
