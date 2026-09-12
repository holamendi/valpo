# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class EnvironmentVariable < Serializer
          fields :id, :service_id, :name, :sensitive, :created_at, :updated_at

          def self.render(variable, reveal: false)
            redacted = variable.sensitive && !reveal
            super(variable).merge(value: redacted ? "********" : variable.value, redacted:)
          end
        end
      end
    end
  end
end
