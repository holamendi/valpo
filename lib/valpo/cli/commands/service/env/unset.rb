# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        module Env
          class Unset < BaseCommand
            desc "Remove an environment variable from an app service"
            argument :service, required: true, desc: "Service name or ID"
            argument :name, required: true, desc: "Environment variable name"
            project_option
            wait_options

            def call(service:, name:, wait:, timeout:, api_url:, project: nil, json: false, args: nil, **)
              reject_extra_arguments!(args)
              current = context(api_url:, json:)
              response = current.request(
                :delete,
                "#{current.service_path(service, project:)}/env/#{segment(name)}"
              )
              current.presenter.operation(current.finish_operation(response, wait:, timeout:))
            end
          end
        end
      end
    end
  end
end
