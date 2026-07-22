# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class List < BaseCommand
          desc "List projects"

          def call(api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            current.presenter.projects(current.request(:get, "/v1/projects"))
          end
        end
      end
    end
  end
end
