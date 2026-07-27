# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Job
        class List < BaseCommand
          desc "List background jobs"

          def call(api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.jobs(current.request(:get, "/v1/jobs"))
          end
        end
      end
    end
  end
end
