# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Release
        class List < BaseCommand
          desc "List releases for an app service"
          argument :service, required: true, desc: "Service name or ID"
          project_option

          def call(service:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.releases(current.request(:get, "#{current.service_path(service, project: project)}/releases"))
          end
        end

        class Rollback < BaseCommand
          desc "Roll back an app service to its previous release"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          wait_options

          def call(service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service, project: project)}/rollback")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end
      end
    end
  end
end
