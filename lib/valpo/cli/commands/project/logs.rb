# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Project
        class Logs < BaseCommand
          desc "Print logs from every service in a project"
          argument :project, required: true, desc: "Project name or ID"
          option :service, desc: "Only include one service name"
          option :tail, desc: "Maximum lines per service"

          def call(project:, api_url:, service: nil, tail: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, config:, json:)
            query = {"service" => service, "tail" => optional_positive_integer(tail, "tail")}.compact
            current.presenter.logs(current.request(:get, "/v1/projects/#{segment(project)}/logs", query:), aggregate: true)
          end
        end
      end
    end
  end
end
