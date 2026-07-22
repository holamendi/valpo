# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Projects
        class ApplyContract < Contract
          json do
            required(:manifest).filled(:string, format?: NONEMPTY)
            optional(:dry_run).filled(:bool)
          end
        end

        class CreateContract < Contract
          json do
            required(:name).filled(:string, format?: NONEMPTY)
          end
        end

        class LogsQueryContract < Contract
          params do
            optional(:tail).filled(:integer, gt?: 0)
            optional(:service).filled(:string, format?: NONEMPTY)
          end
        end

        module_function

        def render(project)
          Fields.call(project, :id, :name, :manifest_digest, :last_applied_at, :created_at, :updated_at).merge(
            service_count: Valpo::Service.where(project_id: project.id).count,
            source_count: Valpo::Source.where(project_id: project.id).count
          )
        end

        def render_source(source)
          Fields.call(
            source, :id, :project_id, :name, :provider, :repository, :ref, :auto_deploy, :status,
            :created_at, :updated_at
          )
        end

        def render_build_target(build_target)
          Fields.call(
            build_target, :id, :project_id, :source_id, :name, :dockerfile, :context, :created_at, :updated_at
          )
        end
      end
    end
  end
end
