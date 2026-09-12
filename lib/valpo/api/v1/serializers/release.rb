# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class Release < Serializer
          fields :id, :service_id, :build_target_id, :version, :source_type, :source_ref, :artifact_ref,
            :image_digest, :artifact_available, :status, :internal_port, :healthcheck_path, :container_name,
            :route_target, :activated_at, :created_at

          field(:build) { ReleaseBuild.render(it) if it.build_strategy }
        end
      end
    end
  end
end
