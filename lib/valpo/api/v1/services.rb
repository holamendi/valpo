# frozen_string_literal: true

module Valpo
  module API
    module V1
      module Services
        class BindDependencyContract < Contract
          json do
            required(:dependency_service_id).filled(:string, format?: NONEMPTY)
          end
        end

        class CreateContract < Contract
          json do
            required(:name).filled(:string, format?: NONEMPTY)
            required(:type).filled(:string, format?: NONEMPTY)
            optional(:version).filled(:string, format?: NONEMPTY)
            optional(:command).array(:string)
            optional(:internal_port).maybe(:integer, gt?: 0, lteq?: 65_535)
            optional(:healthcheck_path).maybe(:string, format?: HEALTHCHECK_PATH)
            optional(:source).hash do
              required(:provider).filled(:string, format?: NONEMPTY)
              required(:repository).filled(:string, format?: NONEMPTY)
              optional(:ref).filled(:string, format?: NONEMPTY)
            end
            optional(:build).hash do
              optional(:dockerfile).filled(:string, format?: NONEMPTY)
              optional(:context).filled(:string, format?: NONEMPTY)
            end
            optional(:deploy).filled(:bool)
          end

          rule(:command).each do
            key.failure("must be a non-empty string") unless value.match?(NONEMPTY)
          end
        end

        class CreateDomainContract < Contract
          json do
            required(:hostname).filled(:string, format?: NONEMPTY)
          end
        end

        class DeleteQueryContract < Contract
          params do
            optional(:force).filled(:string, included_in?: %w[true false])
          end
        end

        class DeployContract < Contract
          json do
            optional(:image).filled(:string, format?: NONEMPTY)
            optional(:ref).filled(:string, format?: NONEMPTY)
            optional(:internal_port).maybe(:integer, gt?: 0, lteq?: 65_535)
            optional(:healthcheck_path).maybe(:string, format?: HEALTHCHECK_PATH)
          end
        end

        class EnvironmentQueryContract < Contract
          params do
            optional(:reveal).filled(:string, included_in?: %w[true false])
          end
        end

        class ListQueryContract < Contract
          params do
            optional(:project).filled(:string, format?: NONEMPTY)
          end
        end

        class TailQueryContract < Contract
          params do
            optional(:tail).filled(:integer, gt?: 0)
          end
        end

        class UpdateContract < Contract
          json do
            optional(:source).hash do
              optional(:provider).filled(:string, format?: NONEMPTY)
              optional(:repository).filled(:string, format?: NONEMPTY)
              optional(:ref).filled(:string, format?: NONEMPTY)
            end
            optional(:build).hash do
              optional(:dockerfile).filled(:string, format?: NONEMPTY)
              optional(:context).filled(:string, format?: NONEMPTY)
            end
            optional(:command).array(:string)
            optional(:internal_port).maybe(:integer, gt?: 0, lteq?: 65_535)
            optional(:healthcheck_path).maybe(:string, format?: HEALTHCHECK_PATH)
            optional(:deploy).filled(:bool)
          end

          rule(:command).each do
            key.failure("must be a non-empty string") unless value.match?(NONEMPTY)
          end

          rule(:source) do
            key.failure("must include at least one source field") if key? && value.empty?
          end

          rule(:build) do
            key.failure("must include at least one build field") if key? && value.empty?
          end
        end

        module_function

        def render(service)
          output = Fields.call(service, :id, :project_id, :name, :kind, :status, :created_at, :updated_at)
          output[:project] = service.project.name
          service.app? ? add_app_configuration(output, service) : add_managed_configuration(output, service)
          output[:dependencies] = dependencies(service)
          output
        end

        def render_dependency(dependency)
          Fields.call(
            dependency, :id, :service_id, :dependency_service_id, :status, :created_at, :updated_at
          )
        end

        def render_domain(domain)
          Fields.call(
            domain, :id, :service_id, :platform_domain_id, :hostname, :kind, :status,
            :verification_error, :verified_at, :route_target, :created_at, :updated_at
          )
        end

        def render_release(release)
          Fields.call(
            release, :id, :service_id, :build_target_id, :version, :source_type, :source_ref, :artifact_ref,
            :image_digest, :status, :internal_port, :healthcheck_path, :container_name, :route_target,
            :activated_at, :created_at
          )
        end

        def add_app_configuration(output, service)
          config = Valpo::AppServiceConfig[service.id]
          build = config.build_target
          source = build&.source
          active_release = Valpo::Release.active_for_service(service.id)
          output[:app] = Fields.call(config, :build_target_id, :internal_port, :healthcheck_path).merge(
            command: config.command,
            port_mode: config.internal_port ? "explicit" : "automatic",
            resolved_internal_port: active_release&.internal_port,
            source: source && Projects.render_source(source),
            build: build && Projects.render_build_target(build)
          )
        end

        def add_managed_configuration(output, service)
          config = Valpo::ManagedServiceConfig[service.id]
          output[:managed] = Fields.call(
            config, :version, :image, :plan, :container_name, :volume_name, :internal_host, :internal_port
          )
        end

        def dependencies(service)
          Valpo::ServiceDependency.where(service_id: service.id).order(:created_at).all.map do
            render_dependency(it)
          end
        end

        private_class_method :add_app_configuration, :add_managed_configuration, :dependencies
      end
    end
  end
end
