# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Auth
        module Token
          class Revoke < BaseCommand
            desc "Revoke an API credential"
            argument :credential, required: true, desc: "Credential ID"

            def call(credential:, api_url:, json: false, args: nil, **)
              reject_extra_arguments!(args)
              result = context(api_url:, json:).request(
                :delete,
                "/v1/api-credentials/#{segment(credential)}"
              )
              if json
                @out.puts JSON.generate(result)
              else
                @out.puts "API credential revoked"
              end
            end
          end
        end
      end
    end
  end
end
