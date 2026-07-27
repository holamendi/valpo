# frozen_string_literal: true

module Valpo
  module API
    module Authentication
      private

      def authenticate_request
        return nil if Valpo::APICredential.active.empty?

        provided = request.env["HTTP_AUTHORIZATION"].to_s
        scheme, token = provided.split(" ", 2)
        credential = Valpo::APICredential.authenticate(token) if scheme == "Bearer"
        request.env["valpo.api_credential"] = credential if credential
        return nil if credential&.allows?(request.request_method)

        response.status = credential ? 403 : 401
        response["WWW-Authenticate"] = "Bearer"
        credential ?
          {error: "forbidden", message: "Credential scope does not allow this operation"} :
          {error: "unauthorized", message: "Unauthorized"}
      end
    end
  end
end
