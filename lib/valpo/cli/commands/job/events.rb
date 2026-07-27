# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Job
        class Events < BaseCommand
          desc "List events for a background job"
          argument :id, required: true, desc: "Job ID"

          def call(id:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.events(current.request(:get, "/v1/jobs/#{segment(id)}/events"))
          end
        end
      end
    end
  end
end
