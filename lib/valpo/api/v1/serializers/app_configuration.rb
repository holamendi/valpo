# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class AppConfiguration < Serializer
          fields :build_target_id, :internal_port, :healthcheck_path

          field(:command) { it.command }
          field(:port_mode) { it.internal_port ? "explicit" : "automatic" }
          field(:resolved_internal_port) { Valpo::Release.active_for_service(it.service_id)&.internal_port }
          field :source do
            source = it.build_target&.source
            Source.render(source) if source
          end
          field :build do
            build = it.build_target
            BuildTarget.render(build) if build
          end
        end
      end
    end
  end
end
