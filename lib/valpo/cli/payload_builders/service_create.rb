# frozen_string_literal: true

module Valpo
  module CLI
    module PayloadBuilders
      class ServiceCreate
        def self.call(
          name:,
          type:,
          version: nil,
          command: nil,
          port: nil,
          healthcheck_path: nil,
          source: nil,
          ref: nil,
          build_strategy: nil,
          dockerfile: nil,
          builder: nil, buildpacks: nil,
          context: nil,
          deploy: false
        )
          validate_options!(
            type:,
            options: {version:, command:, port:, healthcheck_path:}.compact
          )
          validate_build_options!(build_strategy:, dockerfile:)
          source_options = {ref:, build_strategy:, dockerfile:, builder:, buildpacks:, context:}.compact
          if source.nil? && (!source_options.empty? || deploy)
            raise UsageError, "--ref, --build-strategy, --dockerfile, --builder, --buildpacks, --context, and --deploy require --source"
          end
          if source && !Valpo::Services::Registry.app_type?(type)
            raise UsageError, "--source is only valid for web and worker services"
          end

          payload = {
            "name" => name,
            "type" => type,
            "version" => version,
            "command" => command,
            "internal_port" => positive_integer(port, "port"),
            "healthcheck_path" => healthcheck_path
          }.compact
          if source
            payload["source"] = source_spec(source).merge("ref" => ref || "HEAD")
            payload["build"] = {
              "strategy" => build_strategy,
              "dockerfile" => dockerfile,
              "context" => context,
              "builder" => builder, "buildpacks" => buildpacks
            }.compact
            payload["deploy"] = deploy
          end
          payload
        end

        class << self
          private

          def validate_options!(type:, options:)
            Valpo::Services::Registry.validate_options!(type:, options:)
          rescue Valpo::ValidationError => e
            raise UsageError, e.message
          end

          def validate_build_options!(build_strategy:, dockerfile:)
            if build_strategy && !Valpo::Builds::STRATEGIES.include?(build_strategy)
              raise UsageError, "--build-strategy must be auto, dockerfile, or buildpack"
            end
            if dockerfile && build_strategy && build_strategy != "dockerfile"
              raise UsageError, "--dockerfile requires --build-strategy dockerfile"
            end
          end

          def positive_integer(value, name)
            return nil if value.nil? || value.to_s.empty?

            number = Integer(value, 10)
            raise UsageError, "#{name} must be greater than 0" unless number.positive?

            number
          rescue ArgumentError, TypeError
            raise UsageError, "#{name} must be an integer"
          end

          def source_spec(value)
            provider, repository = value.to_s.split(":", 2)
            if provider.to_s.empty? || repository.to_s.empty?
              raise UsageError, "--source must use PROVIDER:OWNER/REPOSITORY"
            end

            {"provider" => provider.downcase, "repository" => repository}
          end
        end
      end
    end
  end
end
