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
              optional(:strategy).filled(:string, included_in?: Valpo::Builds::STRATEGIES)
              optional(:dockerfile).filled(:string, format?: NONEMPTY)
              optional(:context).filled(:string, format?: NONEMPTY)
              optional(:builder).maybe(:string, format?: NONEMPTY)
              optional(:buildpacks).maybe { array(:string) }
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

        class SetEnvironmentVariableContract < Contract
          json do
            required(:value).value(:string)
            optional(:sensitive).filled(:bool)
          end
        end

        class ListQueryContract < Contract
          params do
            optional(:project).filled(:string, format?: NONEMPTY)
          end
        end

        class TailQueryContract < Contract
          params do
            optional(:tail).filled(:integer, gt?: 0, lteq?: 10_000)
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
              optional(:strategy).filled(:string, included_in?: Valpo::Builds::STRATEGIES)
              optional(:dockerfile).filled(:string, format?: NONEMPTY)
              optional(:context).filled(:string, format?: NONEMPTY)
              optional(:builder).maybe(:string, format?: NONEMPTY)
              optional(:buildpacks).maybe { array(:string) }
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
      end
    end
  end
end
