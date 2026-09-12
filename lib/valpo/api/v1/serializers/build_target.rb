# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class BuildTarget < Serializer
          fields :id, :project_id, :source_id, :name, :strategy, :dockerfile, :context, :builder,
            :created_at, :updated_at

          field(:buildpacks) { it.buildpacks }
        end
      end
    end
  end
end
