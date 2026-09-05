# frozen_string_literal: true

require "dry/validation"

module Valpo
  module API
    module V1
      class Contract < Dry::Validation::Contract
        config.validate_keys = true

        NONEMPTY = /\S/
        HEALTHCHECK_PATH = %r{\A/\S*\z}

        class EmptyQuery < Contract
          params do
          end
        end

        class EmptyBody < Contract
          params do
          end
        end
      end
    end
  end
end
