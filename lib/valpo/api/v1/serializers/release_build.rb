# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class ReleaseBuild < Serializer
          field(:strategy) { it.build_strategy }

          def self.render(release)
            metadata = release.build_metadata || {}
            super.merge(
              metadata.slice("dockerfile", "builder", "run_image", "platform", "buildpacks", "processes")
                .transform_keys(&:to_sym)
            )
          end
        end
      end
    end
  end
end
