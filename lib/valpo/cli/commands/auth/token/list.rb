# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Auth
        module Token
          class List < BaseCommand
            desc "List API credentials"

            def call(api_url:, json: false, args: nil, **)
              reject_extra_arguments!(args)
              result = context(api_url:, json:).request(:get, "/v1/api-credentials")
              if json
                @out.puts JSON.generate(result)
              else
                table = result.map do
                  [
                    it.fetch("id"),
                    it.fetch("name"),
                    Array(it.fetch("scopes")).join(","),
                    it["revoked_at"] ? "revoked" : "active"
                  ]
                end
                widths = (0..3).map { |index| table.map { it[index].length }.max.to_i }
                table.each { @out.puts it.each_with_index.map { |value, index| value.ljust(widths[index]) }.join("  ").rstrip }
              end
            end
          end
        end
      end
    end
  end
end
