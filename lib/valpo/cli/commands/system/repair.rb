# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module System
        class Repair < BaseCommand
          desc "Regenerate runtime state from Valpo records"
          wait_options

          def call(wait:, timeout:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            response = current.request(:post, "/v1/system/repair")
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
