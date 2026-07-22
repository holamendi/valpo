# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class Delete < BaseCommand
          desc "Delete an empty project"
          argument :project, required: true, desc: "Project name or ID"
          wait_options

          def call(project:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            response = current.request(:delete, "/v1/projects/#{segment(project)}")
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
