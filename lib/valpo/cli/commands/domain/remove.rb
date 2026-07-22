# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class Remove < BaseCommand
          desc "Remove a hostname from a web service"
          argument :service, required: true, desc: "Service name or ID"
          argument :hostname_or_id, required: true, desc: "Hostname or domain ID"
          project_option
          wait_options

          def call(service:, hostname_or_id:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            response = current.request(:delete, "#{current.service_path(service, project:)}/domains/#{segment(hostname_or_id)}")
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
