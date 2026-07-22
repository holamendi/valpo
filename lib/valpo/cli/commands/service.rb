# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class List < BaseCommand
          desc "List services, optionally within one project"
          project_option

          def call(api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.services(current.request(:get, "/services", query: {"project" => project}.compact))
          end
        end

        class Create < BaseCommand
          desc "Create a web, worker, postgres, or redis service"
          argument :name, required: true, desc: "New service name"
          project_option
          option :type, values: Valpo::Services::Definitions::TYPES.keys, desc: "Service type"
          option :version, desc: "Postgres 16, 17, or 18 (default 18); Redis 7 or 8 (default 8)"
          option :command, type: :array, desc: "Web/worker command as comma-separated arguments"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          option :source, desc: "Source as PROVIDER:OWNER/REPOSITORY"
          option :ref, desc: "Configured branch, tag, commit, or remote HEAD"
          option :dockerfile, desc: "Dockerfile path within the repository"
          option :context, desc: "Docker build context within the repository"
          option :deploy, type: :boolean, default: false, desc: "Deploy after validating and creating the service"
          wait_options
          example [
            "web --project acme --type web --port 3000",
            "web --project acme --type web --source github:acme/backend --deploy",
            "worker --project acme --type worker --command bundle,exec,sidekiq",
            "database --project acme --type postgres --version 18",
            "cache --project acme --type redis --version 8"
          ]

          def call(name:, wait:, timeout:, api_url:, project: nil, type: nil, version: nil, command: nil, port: nil, healthcheck_path: nil, source: nil, ref: nil, dockerfile: nil, context: nil, deploy: false, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            project = required_option!(project, "--project")
            name = service_name(name)
            type = required_option!(type, "--type")
            supplied = {version: version, command: command, port: port, healthcheck_path: healthcheck_path}.compact
            validate_service_options!(type: type, options: supplied)
            source_options = {ref: ref, dockerfile: dockerfile, context: context}.compact
            if source.nil? && (!source_options.empty? || deploy)
              raise UsageError, "--ref, --dockerfile, --context, and --deploy require --source"
            end
            if source && !Valpo::Services::Definitions.app_type?(type)
              raise UsageError, "--source is only valid for web and worker services"
            end
            payload = {
              "name" => name,
              "type" => type,
              "version" => version,
              "command" => command,
              "internal_port" => optional_positive_integer(port, "port"),
              "healthcheck_path" => healthcheck_path
            }.compact
            if source
              payload["source"] = parse_source_spec(source).merge("ref" => ref || "HEAD")
              payload["build"] = {
                "dockerfile" => dockerfile || "Dockerfile",
                "context" => context || "."
              }
              payload["deploy"] = deploy
            end
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "/projects/#{segment(project)}/services", payload)
            operation = current.finish_operation(response, wait: wait, timeout: timeout)
            if source && wait
              service = current.request(:get, "/projects/#{segment(project)}/services/#{segment(name)}")
              current.presenter.operation({"service" => service, "job" => operation})
            else
              current.presenter.operation(operation)
            end
          end
        end

        class Show < BaseCommand
          desc "Show service details"
          argument :service, required: true, desc: "Service name or ID"
          project_option

          def call(service:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.service(current.request(:get, current.service_path(service, project: project)))
          end
        end

        class Update < BaseCommand
          desc "Update an app service's source, build, or runtime configuration"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :source, desc: "Source as PROVIDER:OWNER/REPOSITORY"
          option :ref, desc: "Configured branch, tag, commit, or remote HEAD"
          option :dockerfile, desc: "Dockerfile path within the repository"
          option :context, desc: "Docker build context within the repository"
          option :command, type: :array, desc: "Web/worker command as comma-separated arguments"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          option :clear_command, type: :boolean, default: false, desc: "Use the image's default command"
          option :clear_healthcheck, type: :boolean, default: false, desc: "Use a TCP readiness check"
          option :clear_port, type: :boolean, default: false, desc: "Resolve the web port automatically"
          option :deploy, type: :boolean, default: false, desc: "Deploy after applying the update"
          wait_options
          example [
            "web --project acme --ref release --deploy",
            "web --project acme --clear-port"
          ]

          def call(service:, wait:, timeout:, api_url:, project: nil, source: nil, ref: nil, dockerfile: nil, context: nil, command: nil, port: nil, healthcheck_path: nil, clear_command: false, clear_healthcheck: false, clear_port: false, deploy: false, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            raise UsageError, "--command and --clear-command cannot be used together" if command && clear_command
            raise UsageError, "--healthcheck-path and --clear-healthcheck cannot be used together" if healthcheck_path && clear_healthcheck
            raise UsageError, "--port and --clear-port cannot be used together" if port && clear_port

            payload = {}
            source_changes = source ? parse_source_spec(source) : {}
            source_changes["ref"] = ref if ref
            payload["source"] = source_changes unless source_changes.empty?
            build_changes = {"dockerfile" => dockerfile, "context" => context}.compact
            payload["build"] = build_changes unless build_changes.empty?
            payload["command"] = clear_command ? [] : command if command || clear_command
            payload["internal_port"] = clear_port ? nil : optional_positive_integer(port, "--port") if port || clear_port
            payload["healthcheck_path"] = clear_healthcheck ? nil : healthcheck_path if healthcheck_path || clear_healthcheck
            payload["deploy"] = true if deploy
            raise UsageError, "At least one service update option is required" if payload.empty?

            current = context(api_url: api_url, config: config, json: json)
            path = current.service_path(service, project: project)
            response = current.request(:patch, path, payload)
            operation = current.finish_operation(response, wait: wait, timeout: timeout)
            if wait
              updated = current.request(:get, path)
              current.presenter.operation({"service" => updated, "job" => operation})
            else
              current.presenter.operation(operation)
            end
          end
        end

        class Delete < BaseCommand
          desc "Delete a service and its runtime state"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :force, type: :boolean, default: false, desc: "Confirm destructive deletion"
          wait_options

          def call(service:, force:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            raise UsageError, "--force is required to delete a service" unless force

            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:delete, current.service_path(service, project: project), query: {"force" => true})
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Deploy < BaseCommand
          desc "Deploy a configured source or registry image"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :image, desc: "Registry image and tag instead of the configured source"
          option :ref, desc: "Git branch, tag, or commit SHA (default: configured ref)"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          wait_options

          def call(service:, wait:, timeout:, api_url:, project: nil, image: nil, ref: nil, port: nil, healthcheck_path: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            raise UsageError, "--image and --ref cannot be used together" if image && ref
            payload = {
              "image" => image,
              "ref" => ref,
              "internal_port" => optional_positive_integer(port, "port"),
              "healthcheck_path" => healthcheck_path
            }.compact
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service, project: project)}/deployments", payload)
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Logs < BaseCommand
          desc "Print service container logs"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :tail, desc: "Maximum lines"

          def call(service:, api_url:, project: nil, tail: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:get, "#{current.service_path(service, project: project)}/logs", query: {"tail" => optional_positive_integer(tail, "tail")}.compact)
            current.presenter.logs(response)
          end
        end

        class Restart < BaseCommand
          desc "Restart a service"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          wait_options

          def call(service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            operate(service, "restart", project: project, wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end

          private

          def operate(service, action, project:, wait:, timeout:, api_url:, config:, json:, args:)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service, project: project)}/#{action}")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Stop < Restart
          desc "Stop a service"

          def call(service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            operate(service, "stop", project: project, wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end
        end

        class Env < BaseCommand
          desc "Show managed environment variables injected into an app service"
          argument :service, required: true, desc: "Service name or ID"
          project_option
          option :reveal, type: :boolean, default: false, desc: "Reveal secret values"

          def call(service:, reveal:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:get, "#{current.service_path(service, project: project)}/env", query: ({"reveal" => true} if reveal))
            current.presenter.env(response)
          end
        end

        class Bind < BaseCommand
          desc "Bind a managed dependency to an app service"
          argument :app_service, required: true, desc: "App service reference"
          argument :managed_service, required: true, desc: "Managed service reference"
          project_option
          wait_options

          def call(app_service:, managed_service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            dependency_operation(:post, app_service, managed_service, project: project, wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end

          private

          def dependency_operation(method, app_service, managed_service, project:, wait:, timeout:, api_url:, config:, json:, args:)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            app_id = current.resolver.service_id(app_service, project: project)
            dependency_id = current.resolver.service_id(managed_service, project: project)
            path = "/services/#{app_id}/dependencies"
            payload = {"dependency_service_id" => dependency_id}
            if method == :delete
              path = "#{path}/#{dependency_id}"
              payload = nil
            end
            response = current.request(method, path, payload)
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Unbind < Bind
          desc "Remove a managed dependency from an app service"

          def call(app_service:, managed_service:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            dependency_operation(:delete, app_service, managed_service, project: project, wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end
        end
      end
    end
  end
end
