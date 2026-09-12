# frozen_string_literal: true

module Valpo
  module API
    module V1
      module System
        class ConfigureAppDomainContract < Contract
          json do
            required(:hostname).filled(:string, format?: NONEMPTY)
          end
        end

        class MaintainStorageContract < Contract
          json do
            optional(:dry_run).value(:bool)
          end
        end
      end
    end
  end
end
