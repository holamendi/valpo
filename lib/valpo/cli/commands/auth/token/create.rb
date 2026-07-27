# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Auth
        module Token
          class Create < BaseCommand
            desc "Issue a scoped API credential"
            argument :name, required: true, desc: "Credential name"
            option :scope, type: :array, values: %w[admin read write], desc: "Comma-separated scopes"

            def call(name:, api_url:, scope: nil, json: false, args: nil, **)
              reject_extra_arguments!(args)
              payload = {"name" => name}
              payload["scopes"] = scope if scope
              result = context(api_url:, json:).request(:post, "/v1/api-credentials", payload)
              if json
                @out.puts JSON.generate(result)
              else
                @out.puts "API credential created. Save this token now; it will not be shown again:"
                @out.puts result.fetch("token")
              end
            end
          end
        end
      end
    end
  end
end
