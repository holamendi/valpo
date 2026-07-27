# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        module Env
          class Reconcile < BaseCommand
            desc "Apply the latest environment revision to a running app service"
            argument :service, required: true, desc: "Service name or ID"
            project_option
            wait_options

            def call(service:, wait:, timeout:, api_url:, project: nil, json: false, args: nil, **)
              reject_extra_arguments!(args)
              current = context(api_url:, json:)
              response = current.request(
                :post,
                "#{current.service_path(service, project:)}/env/reconcile"
              )
              current.presenter.operation(current.finish_operation(response, wait:, timeout:))
            end
          end
        end
      end
    end
  end
end
