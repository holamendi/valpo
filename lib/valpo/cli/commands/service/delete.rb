# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Delete < BaseCommand
          desc "Delete a service and its runtime state"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :force, type: :boolean, default: false, desc: "Confirm destructive deletion"
          wait_options

          def call(service:, force:, wait:, timeout:, api_url:, project: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            raise UsageError, "--force is required to delete a service" unless force

            current = context(api_url:, json:)
            response = current.request(:delete, current.service_path(service, project:), query: {"force" => true})
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
