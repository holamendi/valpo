# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class Apply < BaseCommand
          desc "Reconcile a project from a valpo.toml manifest"
          argument :file, required: true, desc: "Path to valpo.toml"
          option :dry_run, type: :boolean, default: false, desc: "Preview changes without applying them"
          wait_options

          def call(file:, dry_run:, wait:, timeout:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            response = current.request(:post, "/v1/projects/apply", {"manifest" => read_file(file), "dry_run" => dry_run})
            if dry_run
              current.presenter.preview(response)
            else
              current.presenter.operation(current.finish_operation(response, wait:, timeout:))
            end
          end
        end
      end
    end
  end
end
