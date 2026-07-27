# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Job
        class Wait < BaseCommand
          desc "Wait for a background job and stream new events"
          argument :id, required: true, desc: "Job ID"
          option :timeout, default: DEFAULT_TIMEOUT, desc: "Maximum wait in seconds"

          def call(id:, timeout:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            current.presenter.operation(current.waiter.wait(id, timeout:))
          end
        end
      end
    end
  end
end
