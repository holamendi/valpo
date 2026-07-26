# frozen_string_literal: true

module Valpo
  module CLI
    module PayloadBuilders
      class ServiceUpdate
        def self.call(
          source: nil,
          ref: nil,
          build_strategy: nil,
          dockerfile: nil,
          context: nil,
          command: nil,
          port: nil,
          healthcheck_path: nil,
          clear_command: false,
          clear_healthcheck: false,
          clear_port: false,
          deploy: false
        )
          raise UsageError, "--command and --clear-command cannot be used together" if command && clear_command
          if healthcheck_path && clear_healthcheck
            raise UsageError, "--healthcheck-path and --clear-healthcheck cannot be used together"
          end
          raise UsageError, "--port and --clear-port cannot be used together" if port && clear_port
          if build_strategy && !Valpo::Builds::STRATEGIES.include?(build_strategy)
            raise UsageError, "--build-strategy must be auto, dockerfile, or buildpack"
          end
          if dockerfile && build_strategy && build_strategy != "dockerfile"
            raise UsageError, "--dockerfile requires --build-strategy dockerfile"
          end

          payload = {}
          source_changes = source ? source_spec(source) : {}
          source_changes["ref"] = ref if ref
          payload["source"] = source_changes unless source_changes.empty?
          build_changes = {"strategy" => build_strategy, "dockerfile" => dockerfile, "context" => context}.compact
          payload["build"] = build_changes unless build_changes.empty?
          payload["command"] = clear_command ? [] : command if command || clear_command
          payload["internal_port"] = clear_port ? nil : positive_integer(port) if port || clear_port
          if healthcheck_path || clear_healthcheck
            payload["healthcheck_path"] = clear_healthcheck ? nil : healthcheck_path
          end
          payload["deploy"] = true if deploy
          raise UsageError, "At least one service update option is required" if payload.empty?

          payload
        end

        class << self
          private

          def positive_integer(value)
            number = Integer(value, 10)
            raise UsageError, "--port must be greater than 0" unless number.positive?

            number
          rescue ArgumentError, TypeError
            raise UsageError, "--port must be an integer"
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
