# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Show < BaseCommand
          desc "Show service details"
          argument :service, required: true, desc: "Service name or ID"
          project_option

          def call(service:, api_url:, project: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.service(current.request(:get, current.service_path(service, project:)))
          end
        end
      end
    end
  end
end
