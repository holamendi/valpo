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
            removed = store.delete
            result = {"authenticated" => false, "provider" => provider, "removed" => removed}
            if json
              @out.puts JSON.generate(result)
            else
              @out.puts removed ? "Logged out of GitHub" : "GitHub authentication was not configured"
            end
          end
        end
      end
    end
  end
end
