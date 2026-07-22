# frozen_string_literal: true

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
    end
  end
end
