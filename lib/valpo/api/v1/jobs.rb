# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Jobs
        class EventListQueryContract < Contract
          params do
            optional(:after).filled(:string, format?: NONEMPTY)
            optional(:limit).filled(:integer, gt?: 0, lteq?: Valpo::Jobs::Queue::MAX_PAGE_LIMIT)
          end
        end

        class ListQueryContract < Contract
          params do
            optional(:limit).filled(:integer, gt?: 0, lteq?: Valpo::Jobs::Queue::MAX_PAGE_LIMIT)
          end
        end
      end
    end
  end
end
