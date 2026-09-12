# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Projects
        class ApplyContract < Contract
          json do
            required(:manifest).filled(:string, format?: NONEMPTY)
            optional(:dry_run).filled(:bool)
          end
        end

        class CreateContract < Contract
          json do
            required(:name).filled(:string, format?: NONEMPTY)
          end
        end

        class LogsQueryContract < Contract
          params do
            optional(:tail).filled(:integer, gt?: 0, lteq?: 10_000)
            optional(:service).filled(:string, format?: NONEMPTY)
          end
        end
      end
    end
  end
end
