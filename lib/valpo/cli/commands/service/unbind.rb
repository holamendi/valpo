# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Unbind < Bind
          desc "Remove a managed dependency from an app service"

          def call(app_service:, managed_service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            dependency_operation(:delete, app_service, managed_service, project:, wait:, timeout:, api_url:, config:, json:, args:)
          end
        end
      end
    end
  end
end
