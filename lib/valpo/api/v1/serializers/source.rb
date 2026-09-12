# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class Source < Serializer
          fields :id, :project_id, :name, :provider, :repository, :ref, :auto_deploy, :status,
            :created_at, :updated_at
        end
      end
    end
  end
end
