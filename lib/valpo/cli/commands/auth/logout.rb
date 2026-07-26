# frozen_string_literal: true

require "io/console"
require "json"

module Valpo
  module CLI
    module Commands
      module Auth
        class Logout < Base
          desc "Remove source-provider authentication"
          argument :provider, required: true, desc: "Source provider (github)"

          def call(provider:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            provider = github!(provider)
            store, = credential_store(config)
            app_result = context(api_url:, config:, json:).request(:delete, "/v1/auth/github")
            removed_pat = store.delete
            result = app_result.merge(
              "authenticated" => false,
              "provider" => provider,
              "removed" => app_result.fetch("removed") || removed_pat
            )
            if json
              @out.puts JSON.generate(result)
            else
              @out.puts result.fetch("removed") ? "Removed local GitHub authentication" : "GitHub authentication was not configured"
            end
          end
        end
      end
    end
  end
end
