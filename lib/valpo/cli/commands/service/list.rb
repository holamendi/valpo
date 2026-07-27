# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class List < BaseCommand
          desc "List services, optionally within one project"
          project_option

          def call(api_url:, project: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.services(current.request(:get, "/v1/services", query: {"project" => project}.compact))
          end
        end
      end
    end
  end
end
