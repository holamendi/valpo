# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class Create < BaseCommand
          desc "Create a web, worker, postgres, or redis service"
          argument :name, required: true, desc: "New service name"
          project_option
          option :type, values: Valpo::Services::Registry.names, desc: "Service type"
          option :version, desc: "Postgres 16, 17, or 18 (default 18); Redis 7 or 8 (default 8)"
          option :command, type: :array, desc: "Web/worker command as comma-separated arguments"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          option :source, desc: "Source as PROVIDER:OWNER/REPOSITORY"
          option :ref, desc: "Configured branch, tag, commit, or remote HEAD"
          option :build_strategy, values: Valpo::Builds::STRATEGIES, desc: "Build strategy: auto, dockerfile, or buildpack"
          option :dockerfile, desc: "Dockerfile path within the repository"
          option :context, desc: "Build context within the repository"
          option :deploy, type: :boolean, default: false, desc: "Deploy after validating and creating the service"
          wait_options
          example [
            "web --project acme --type web --port 3000",
            "web --project acme --type web --source github:acme/backend --deploy",
            "worker --project acme --type worker --command bundle,exec,sidekiq",
            "database --project acme --type postgres --version 18",
            "cache --project acme --type redis --version 8"
          ]

          def call(name:, wait:, timeout:, api_url:, project: nil, type: nil, version: nil, command: nil, port: nil, healthcheck_path: nil, source: nil, ref: nil, build_strategy: nil, dockerfile: nil, context: nil, deploy: false, json: false, args: nil, **)
            reject_extra_arguments!(args)
            project = required_option!(project, "--project")
            name = service_name(name)
            type = required_option!(type, "--type")
            payload = PayloadBuilders::ServiceCreate.call(
              name:,
              type:,
              version:,
              command:,
              port:,
              healthcheck_path:,
              source:,
              ref:,
              build_strategy:,
              dockerfile:,
              context:,
              deploy:
            )
            current = context(api_url:, json:)
            response = current.request(:post, "/v1/projects/#{segment(project)}/services", payload)
            operation = current.finish_operation(response, wait:, timeout:)
            if source && wait
              service = current.request(:get, "/v1/projects/#{segment(project)}/services/#{segment(name)}")
              current.presenter.operation({"service" => service, "job" => operation})
            else
              current.presenter.operation(operation)
            end
          end
        end
      end
    end
  end
end
