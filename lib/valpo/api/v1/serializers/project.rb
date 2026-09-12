# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class Project < Serializer
          fields :id, :name, :manifest_digest, :last_applied_at, :created_at, :updated_at

          field(:service_count) { Valpo::Service.where(project_id: it.id).count }
          field(:source_count) { Valpo::Source.where(project_id: it.id).count }
        end
      end
    end
  end
end
