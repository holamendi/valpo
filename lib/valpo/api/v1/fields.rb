# frozen_string_literal: true

require "time"

module Valpo
  module API
    module V1
      module Fields
        module_function

        def call(subject, *keys)
          keys.to_h { [it, value(subject[it])] }
        end

        def value(input)
          input.respond_to?(:iso8601) ? input.utc.iso8601 : input
        end
      end
    end
  end
end
