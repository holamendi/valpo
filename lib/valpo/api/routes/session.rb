# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "session") do |r|
        # GET /v1/session — inspect the authenticated API credential.
        r.get true do
          validate_query
          V1::APICredentials.render(request.env.fetch("valpo.api_credential"))
        end

        if r.delete?
          # DELETE /v1/session — revoke the authenticated API credential.
          r.is do
            validate_query
            credential = request.env.fetch("valpo.api_credential")
            credential.revoke!
            {revoked: true, credential: V1::APICredentials.render(credential)}
          end
        end
        not_found("Route not found")
      end
    end
  end
end
