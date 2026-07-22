# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
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
            current = context(api_url:, config:, json:)
            response = current.request(:post, "#{current.service_path(service, project:)}/deployments", payload)
            current.presenter.operation(current.finish_operation(response, wait:, timeout:))
          end
        end
      end
    end
  end
end
