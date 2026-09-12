# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Serializers
        class Service < Serializer
          fields :id, :project_id, :name, :status, :created_at, :updated_at

          field(:type) { it.kind }
          field(:project) { it.project.name }
          field :dependencies do
            ServiceDependency.render_many(
              Valpo::ServiceDependency.where(service_id: it.id).order(:created_at).all
            )
          end

          field :app, if: -> { it.app? } do
            AppConfiguration.render(Valpo::AppServiceConfig[it.id])
          end

          field :managed, if: -> { !it.app? } do
            ManagedConfiguration.render(Valpo::ManagedServiceConfig[it.id])
          end
        end
      end
    end
  end
end
