# frozen_string_literal: true

require "ipaddr"

module Valpo
  module API
    module RequestHelpers
      private

      def validate_body(contract)
        payload = request.POST
        unless request.env["valpo.json_body"] && payload.is_a?(Hash) && !payload.key?("_json")
          raise BadRequest, "Request body must be a JSON object"
        end

        validate_contract(contract, payload)
      end

      def validate_query(contract = V1::Contract::EmptyQuery)
        validate_contract(contract, request.GET)
      end

      def validate_contract(contract, input)
        result = contract.new.call(input)
        return result.to_h if result.success?

        details = result.errors.map do
          {
            field: it.path.to_a.join("."),
            code: (it.predicate || :invalid).to_s.delete_suffix("?"),
            message: it.text
          }
        end
        raise BadRequest.new(details:)
      end

      def not_found(message)
        response.status = 404
        {error: "not_found", message:}
      end

      def require_admin_credential!(bootstrap_scopes: nil)
        credential = request.env["valpo.api_credential"]
        return if credential&.admin?
        if !Valpo::ControlPlaneState.api_bootstrapped? && Array(bootstrap_scopes).include?("admin")
          raise Valpo::ForbiddenError, "API bootstrap is restricted to a local request" unless local_request?

          return
        end

        raise Valpo::ForbiddenError, "An admin API credential is required"
      end

      def local_request?
        IPAddr.new(request.env["REMOTE_ADDR"].to_s).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
