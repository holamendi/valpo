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
          dockerfile: nil,
          context: nil,
          deploy: false
        )
          validate_options!(
            type:,
            options: {version:, command:, port:, healthcheck_path:}.compact
          )
          source_options = {ref:, dockerfile:, context:}.compact
          if source.nil? && (!source_options.empty? || deploy)
            raise UsageError, "--ref, --dockerfile, --context, and --deploy require --source"
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
              "dockerfile" => dockerfile || "Dockerfile",
              "context" => context || "."
            }
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
