# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class List < BaseCommand
          desc "List projects"

          def call(api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.projects(current.request(:get, "/projects"))
          end
        end

        class Create < BaseCommand
          desc "Create a project"
          argument :name, required: true, desc: "Lowercase project name"

          def call(name:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.project(current.request(:post, "/projects", {"name" => name}))
          end
        end

        class Show < BaseCommand
          desc "Show project details"
          argument :project, required: true, desc: "Project name or ID"

          def call(project:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.project(current.request(:get, "/projects/#{segment(project)}"))
          end
        end

        class Delete < BaseCommand
          desc "Delete an empty project"
          argument :project, required: true, desc: "Project name or ID"
          wait_options

          def call(project:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:delete, "/projects/#{segment(project)}")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Apply < BaseCommand
          desc "Reconcile a project from a valpo.toml manifest"
          argument :file, required: true, desc: "Path to valpo.toml"
          option :dry_run, type: :boolean, default: false, desc: "Preview changes without applying them"
          wait_options

          def call(file:, dry_run:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "/projects/apply", {"manifest" => read_file(file), "dry_run" => dry_run})
            if dry_run
              current.presenter.preview(response)
            else
              current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
            end
          end
        end

        class Logs < BaseCommand
          desc "Print logs from every service in a project"
          argument :project, required: true, desc: "Project name or ID"
          option :service, desc: "Only include one service name"
          option :tail, desc: "Maximum lines per service"

          def call(project:, api_url:, service: nil, tail: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            query = {"service" => service, "tail" => optional_positive_integer(tail, "tail")}.compact
            current.presenter.logs(current.request(:get, "/projects/#{segment(project)}/logs", query: query), aggregate: true)
          end
        end
      end
    end
  end
end
