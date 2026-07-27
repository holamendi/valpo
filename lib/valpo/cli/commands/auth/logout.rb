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

          def call(provider:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            github!(provider)
            result = context(api_url:, json:).request(:delete, "/v1/auth/github")
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
