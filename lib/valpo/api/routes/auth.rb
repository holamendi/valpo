# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("/v1", "auth") do |r|
        r.on "github" do
          # GET /v1/auth/github — show GitHub App authentication status.
          r.get true do
            validate_query
            github_setup.status
          end

          # POST /v1/auth/github — create a one-time GitHub App setup URL.
          r.post true do
            validate_query
            payload = validate_body(V1::GitHub::CreateSetupContract)
            response.status = 201
            github_setup.start(organization: payload[:organization])
          end

          if r.delete?
            # DELETE /v1/auth/github — remove the local GitHub App credentials.
            r.is do
              validate_query
              removed = github_setup.logout
              {authenticated: false, provider: "github", removed:}
            end
          end
        end
        not_found("Route not found")
      end
    end
  end
end
