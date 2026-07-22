# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Env < BaseCommand
          desc "Show managed environment variables injected into an app service"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :reveal, type: :boolean, default: false, desc: "Reveal secret values"

          def call(service:, reveal:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            response = current.request(:get, "#{current.service_path(service, project:)}/env", query: ({"reveal" => true} if reveal))
            current.presenter.env(response)
          end
        end
      end
    end
  end
end
