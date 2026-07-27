# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class Show < BaseCommand
          desc "Show project details"
          argument :project, required: true, desc: "Project name or ID"

          def call(project:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.project(current.request(:get, "/v1/projects/#{segment(project)}"))
          end
        end
      end
    end
  end
end
