# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Job
        class List < BaseCommand
          desc "List background jobs"

          def call(api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.jobs(current.request(:get, "/jobs"))
          end
        end

        class Show < BaseCommand
          desc "Show a background job"
          argument :id, required: true, desc: "Job ID"

          def call(id:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.operation(current.request(:get, "/jobs/#{segment(id)}"))
          end
        end

        class Wait < BaseCommand
          desc "Wait for a background job and stream new events"
          argument :id, required: true, desc: "Job ID"
          option :timeout, default: DEFAULT_TIMEOUT, desc: "Maximum wait in seconds"

          def call(id:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.operation(current.waiter.wait(id, timeout: timeout))
          end
        end

        class Events < BaseCommand
          desc "List events for a background job"
          argument :id, required: true, desc: "Job ID"

          def call(id:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.events(current.request(:get, "/jobs/#{segment(id)}/events"))
          end
        end
      end
    end
  end
end
