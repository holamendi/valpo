# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        class List < BaseCommand
          desc "List services, optionally within one project"
          argument :project, desc: "Project name or ID"

          def call(api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.services(current.request(:get, "/services", query: {"project" => project}.compact))
          end
        end

        class Create < BaseCommand
          desc "Create a web, worker, postgres, or redis service"
          argument :reference, required: true, label: "PROJECT/NAME", desc: "New service as PROJECT/NAME"
          option :type, values: Valpo::Services::Definitions::TYPES.keys, desc: "Service type"
          option :version, desc: "Postgres 16, 17, or 18 (default 18); Redis 7 or 8 (default 8)"
          option :command, type: :array, desc: "Web/worker command as comma-separated arguments"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          wait_options
          example [
            "acme/web --type web --port 3000",
            "acme/worker --type worker --command bundle,exec,sidekiq",
            "acme/database --type postgres --version 18",
            "acme/cache --type redis --version 8"
          ]

          def call(reference:, wait:, timeout:, api_url:, type: nil, version: nil, command: nil, port: nil, healthcheck_path: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            type = required_option!(type, "--type")
            supplied = {version: version, command: command, port: port, healthcheck_path: healthcheck_path}.compact
            validate_service_options!(type: type, options: supplied)
            project, name = split_service_reference(reference)
            payload = {
              "name" => name,
              "type" => type,
              "version" => version,
              "command" => command,
              "internal_port" => optional_positive_integer(port, "port"),
              "healthcheck_path" => healthcheck_path
            }.compact
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "/projects/#{segment(project)}/services", payload)
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Show < BaseCommand
          desc "Show service details"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"

          def call(service:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.service(current.request(:get, current.service_path(service)))
          end
        end

        class Delete < BaseCommand
          desc "Delete a service and its runtime state"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          option :force, type: :boolean, default: false, desc: "Confirm destructive deletion"
          wait_options

          def call(service:, force:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            raise UsageError, "--force is required to delete a service" unless force

            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:delete, current.service_path(service), query: {"force" => true})
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Deploy < BaseCommand
          desc "Deploy a configured source or registry image"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          option :image, desc: "Registry image and tag instead of the configured source"
          option :ref, desc: "Git branch, tag, or commit SHA (default: configured ref)"
          option :port, desc: "Web container port"
          option :healthcheck_path, desc: "Web health check path beginning with /"
          wait_options

          def call(service:, wait:, timeout:, api_url:, image: nil, ref: nil, port: nil, healthcheck_path: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            raise UsageError, "--image and --ref cannot be used together" if image && ref
            payload = {
              "image" => image,
              "ref" => ref,
              "internal_port" => optional_positive_integer(port, "port"),
              "healthcheck_path" => healthcheck_path
            }.compact
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service)}/deployments", payload)
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Logs < BaseCommand
          desc "Print service container logs"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          option :tail, desc: "Maximum lines"

          def call(service:, api_url:, tail: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:get, "#{current.service_path(service)}/logs", query: {"tail" => optional_positive_integer(tail, "tail")}.compact)
            current.presenter.logs(response)
          end
        end

        class Restart < BaseCommand
          desc "Restart a service"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          wait_options

          def call(service:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            operate(service, "restart", wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end

          private

          def operate(service, action, wait:, timeout:, api_url:, config:, json:, args:)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service)}/#{action}")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Stop < Restart
          desc "Stop a service"

          def call(service:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            operate(service, "stop", wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end
        end

        class Env < BaseCommand
          desc "Show managed environment variables injected into an app service"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          option :reveal, type: :boolean, default: false, desc: "Reveal secret values"

          def call(service:, reveal:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:get, "#{current.service_path(service)}/env", query: ({"reveal" => true} if reveal))
            current.presenter.env(response)
          end
        end

        class Bind < BaseCommand
          desc "Bind a managed dependency to an app service"
          argument :app_service, required: true, desc: "App service reference"
          argument :managed_service, required: true, desc: "Managed service reference"
          wait_options

          def call(app_service:, managed_service:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            dependency_operation(:post, app_service, managed_service, wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end

          private

          def dependency_operation(method, app_service, managed_service, wait:, timeout:, api_url:, config:, json:, args:)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            app_id = current.resolver.service_id(app_service)
            dependency_id = current.resolver.service_id(managed_service)
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

          def call(app_service:, managed_service:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            dependency_operation(:delete, app_service, managed_service, wait: wait, timeout: timeout, api_url: api_url, config: config, json: json, args: args)
          end
        end
      end
    end
  end
end
