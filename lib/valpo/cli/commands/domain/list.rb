# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class List < BaseCommand
          desc "List domains attached to a web service"
          argument :service, required: true, desc: "Service name or ID"
          project_option

          def call(service:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            current.presenter.domains(current.request(:get, "#{current.service_path(service, project:)}/domains"))
          end
        end
      end
    end
  end
end
