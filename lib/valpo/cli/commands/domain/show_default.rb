# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class ShowDefault < BaseCommand
          desc "Show the platform app domain"

          def call(api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.app_domain(current.request(:get, "/v1/system/app-domain"))
          end
        end
      end
    end
  end
end
