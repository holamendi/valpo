# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Release
        class List < BaseCommand
          desc "List releases for an app service"
          argument :service, required: true, desc: "Service name or ID"
          project_option

          def call(service:, api_url:, project: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.releases(current.request(:get, "#{current.service_path(service, project:)}/releases"))
          end
        end
      end
    end
  end
end
