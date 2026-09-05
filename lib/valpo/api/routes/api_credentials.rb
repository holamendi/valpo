# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "api-credentials") do |r|
        # GET /v1/api-credentials — list API credentials.
        r.get true do
          validate_query
          require_admin_credential!
          Valpo::APICredential.order(:created_at).all.map { V1::APICredentials.render(it) }
        end

        # POST /v1/api-credentials — issue an API credential.
        r.post true do
          validate_query
          payload = validate_body(V1::APICredentials::CreateContract)
          scopes = payload.fetch(:scopes, ["admin"])
          require_admin_credential!(bootstrap_scopes: scopes)
          issuer = Valpo::ControlPlaneState.api_bootstrapped? ? :issue : :bootstrap
          credential, token = Valpo::APICredential.public_send(issuer, name: payload.fetch(:name), scopes:)
          response.status = 201
          V1::APICredentials.render(credential).merge(token:)
        end

        r.on String do
          credential = Valpo::APICredential[it]
          next not_found("API credential not found") unless credential

          if r.delete?
            # DELETE /v1/api-credentials/{credential} — revoke an API credential.
            r.is do
              validate_query
              require_admin_credential!
              credential.revoke!
              {revoked: true, credential: V1::APICredentials.render(credential)}
            end
          end
        end
        not_found("Route not found")
      end
    end
  end
end
