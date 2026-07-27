# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module System
        class Maintenance < BaseCommand
          desc "Clean stale Valpo-owned storage"
          option :dry_run, type: :boolean, default: false, desc: "Preview without deleting anything"
          wait_options

          def call(dry_run:, wait:, timeout:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            response = current.request(:post, "/v1/system/maintenance", {"dry_run" => dry_run})
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
