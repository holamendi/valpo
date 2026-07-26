# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Update < BaseCommand
          desc "Update an app service's source, build, or runtime configuration"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :source, desc: "Source as PROVIDER:OWNER/REPOSITORY"
          option :ref, desc: "Configured branch, tag, commit, or remote HEAD"
          option :build_strategy, values: Valpo::Builds::STRATEGIES, desc: "Build strategy: auto, dockerfile, or buildpack"
          option :dockerfile, desc: "Dockerfile path within the repository"
          option :context, desc: "Build context within the repository"
          option :command, type: :array, desc: "Web/worker command as comma-separated arguments"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          option :clear_command, type: :boolean, default: false, desc: "Use the image's default command"
          option :clear_healthcheck, type: :boolean, default: false, desc: "Use the default HTTP root readiness check"
          option :clear_port, type: :boolean, default: false, desc: "Resolve the web port automatically"
          option :deploy, type: :boolean, default: false, desc: "Deploy after applying the update"
          wait_options
          example [
            "web --project acme --ref release --deploy",
            "web --project acme --clear-port"
          ]

          def call(service:, wait:, timeout:, api_url:, project: nil, source: nil, ref: nil, build_strategy: nil, dockerfile: nil, context: nil, command: nil, port: nil, healthcheck_path: nil, clear_command: false, clear_healthcheck: false, clear_port: false, deploy: false, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            payload = PayloadBuilders::ServiceUpdate.call(
              source:,
              ref:,
              build_strategy:,
              dockerfile:,
              context:,
              command:,
              port:,
              healthcheck_path:,
              clear_command:,
              clear_healthcheck:,
              clear_port:,
              deploy:
            )

            current = context(api_url:, config:, json:)
            path = current.service_path(service, project:)
            response = current.request(:patch, path, payload)
            operation = current.finish_operation(response, wait:, timeout:)
            if wait
              updated = current.request(:get, path)
              current.presenter.operation({"service" => updated, "job" => operation})
            else
              current.presenter.operation(operation)
            end
          end
        end
      end
    end
  end
end
