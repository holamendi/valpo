# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Logs < BaseCommand
          desc "Print service container logs"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :tail, desc: "Maximum lines"

          def call(service:, api_url:, project: nil, tail: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            response = current.request(:get, "#{current.service_path(service, project:)}/logs", query: {"tail" => optional_positive_integer(tail, "tail")}.compact)
            current.presenter.logs(response)
          end
        end
      end
    end
  end
end
