# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class ManagedConfiguration < Serializer
          fields :version, :image, :container_name, :volume_name, :internal_host, :internal_port
        end
      end
    end
  end
end
