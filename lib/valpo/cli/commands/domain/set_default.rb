# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class SetDefault < BaseCommand
          desc "Set and verify the platform app domain"
          argument :hostname, required: true, desc: "Base hostname without *."
          wait_options

          def call(hostname:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            response = current.request(:put, "/v1/system/app-domain", {"hostname" => hostname})
            if response["job"]
              current.presenter.operation(current.finish_operation(response, wait:, timeout:))
            else
              current.presenter.app_domain("active" => response["app_domain"], "candidate" => nil)
            end
          end
        end
      end
    end
  end
end
