# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class JobEvent < Serializer
          fields :id, :job_id, :stream, :message, :created_at
        end
      end
    end
  end
end
