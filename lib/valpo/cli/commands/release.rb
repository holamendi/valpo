# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Release
        class List < BaseCommand
          desc "List releases for an app service"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"

          def call(service:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.releases(current.request(:get, "#{current.service_path(service)}/releases"))
          end
        end

        class Rollback < BaseCommand
          desc "Roll back an app service to its previous release"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          wait_options

          def call(service:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service)}/rollback")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end
      end
    end
  end
end
