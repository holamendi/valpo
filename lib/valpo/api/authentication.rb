# frozen_string_literal: true

require "rack/utils"
require "valpo"

module Valpo
  module API
    module Authentication
      private

      def authenticate_request
        token = api_token
        return nil if token.nil?

        expected = "Bearer #{token}"
        provided = request.env["HTTP_AUTHORIZATION"].to_s
        return nil if provided.bytesize == expected.bytesize && Rack::Utils.secure_compare(provided, expected)

        response.status = 401
        response["WWW-Authenticate"] = "Bearer"
        {error: "unauthorized", message: "Unauthorized"}
      end

      def api_token
        (Valpo.config || Valpo::Config.load).api_token
      end
    end
  end
end
