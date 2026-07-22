# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Restart < BaseCommand
          desc "Restart a service"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          wait_options

          def call(service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            operate(service, "restart", project:, wait:, timeout:, api_url:, config:, json:, args:)
          end

          private

          def operate(service, action, project:, wait:, timeout:, api_url:, config:, json:, args:)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            response = current.request(:post, "#{current.service_path(service, project:)}/#{action}")
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
