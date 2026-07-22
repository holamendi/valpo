# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Bind < BaseCommand
          desc "Bind a managed dependency to an app service"
          argument :app_service, required: true, desc: "App service reference"
          argument :managed_service, required: true, desc: "Managed service reference"
          project_option
          wait_options

          def call(app_service:, managed_service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            dependency_operation(:post, app_service, managed_service, project:, wait:, timeout:, api_url:, config:, json:, args:)
          end

          private

          def dependency_operation(method, app_service, managed_service, project:, wait:, timeout:, api_url:, config:, json:, args:)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            app_id = current.resolver.service_id(app_service, project:)
            dependency_id = current.resolver.service_id(managed_service, project:)
            path = "/v1/services/#{app_id}/dependencies"
            payload = {"dependency_service_id" => dependency_id}
            if method == :delete
              path = "#{path}/#{dependency_id}"
              payload = nil
            end
            response = current.request(method, path, payload)
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
