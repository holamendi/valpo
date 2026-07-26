# frozen_string_literal: true

require "io/console"
require "json"

module Valpo
  module CLI
    module Commands
      module Auth
        class Status < Base
          desc "Show source-provider authentication status"
          argument :provider, required: true, desc: "Source provider (github)"

          def call(provider:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            provider = github!(provider)
            store, path = credential_store(config)
            app_result = context(api_url:, config:, json:).request(:get, "/v1/auth/github")
            result = if app_result.fetch("authenticated") || !store.read
              app_result
            else
              {"authenticated" => true, "provider" => provider, "mode" => "pat", "path" => path}
            end
            if json
              @out.puts JSON.generate(result)
            else
              @out.puts result.fetch("authenticated") ? "GitHub authentication is configured" : "GitHub authentication is not configured"
            end
          end
        end
      end
    end
  end
end
