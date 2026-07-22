# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Job
        class Show < BaseCommand
          desc "Show a background job"
          argument :id, required: true, desc: "Job ID"

          def call(id:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            current.presenter.operation(current.request(:get, "/v1/jobs/#{segment(id)}"))
          end
        end
      end
    end
  end
end
