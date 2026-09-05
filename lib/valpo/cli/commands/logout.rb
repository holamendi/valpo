# frozen_string_literal: true

require "json"

module Valpo
  module CLI
    module Commands
      class Logout < BaseCommand
        desc "Remove a saved login, optionally revoking its token"
        option :revoke, type: :boolean, default: false, desc: "Revoke the saved credential on its server before removing it"

        def call(api_url:, revoke:, json: false, args: nil, **)
          reject_extra_arguments!(args)
          raise UsageError, "Use logout --server NAME, not --api-url" if api_url

          result = CLI.sessions.logout(name: server, revoke:)
          if json
            @out.puts JSON.generate(result)
          else
            @out.puts "Logged out of #{result.fetch("server")}#{" and revoked its token" if revoke}"
            @out.puts "The server credential remains valid; use --revoke to revoke it." unless revoke
          end
        end
      end
    end
  end
end
