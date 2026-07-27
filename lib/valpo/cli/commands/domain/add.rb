# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class Add < BaseCommand
          desc "Attach a hostname to a web service"
          argument :service, required: true, desc: "Service name or ID"
          argument :hostname, required: true, desc: "DNS hostname"
          project_option
          wait_options

          def call(service:, hostname:, wait:, timeout:, api_url:, project: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            response = current.request(:post, "#{current.service_path(service, project:)}/domains", {"hostname" => hostname})
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
