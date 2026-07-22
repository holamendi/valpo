# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class Create < BaseCommand
          desc "Create a project"
          argument :name, required: true, desc: "Lowercase project name"

          def call(name:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            current.presenter.project(current.request(:post, "/v1/projects", {"name" => name}))
          end
        end
      end
    end
  end
end
