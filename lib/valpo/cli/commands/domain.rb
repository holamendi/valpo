# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class ShowDefault < BaseCommand
          desc "Show the platform app domain"

          def call(api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.app_domain(current.request(:get, "/system/app-domain"))
          end
        end

        class SetDefault < BaseCommand
          desc "Set and verify the platform app domain"
          argument :hostname, required: true, desc: "Base hostname without *."
          wait_options

          def call(hostname:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:put, "/system/app-domain", {"hostname" => hostname})
            if response["job"]
              current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
            else
              current.presenter.app_domain("active" => response["app_domain"], "candidate" => nil)
            end
          end
        end

        class List < BaseCommand
          desc "List domains attached to a web service"
          argument :service, required: true, desc: "Service name or ID"
          project_option

          def call(service:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.domains(current.request(:get, "#{current.service_path(service, project: project)}/domains"))
          end
        end

        class Add < BaseCommand
          desc "Attach a hostname to a web service"
          argument :service, required: true, desc: "Service name or ID"
          argument :hostname, required: true, desc: "DNS hostname"
          project_option
          wait_options

          def call(service:, hostname:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service, project: project)}/domains", {"hostname" => hostname})
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Remove < BaseCommand
          desc "Remove a hostname from a web service"
          argument :service, required: true, desc: "Service name or ID"
          argument :hostname_or_id, required: true, desc: "Hostname or domain ID"
          project_option
          wait_options

          def call(service:, hostname_or_id:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:delete, "#{current.service_path(service, project: project)}/domains/#{segment(hostname_or_id)}")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Verify < BaseCommand
          desc "Retry verification of a web-service domain"
          argument :service, required: true, desc: "Service name or ID"
          argument :hostname_or_id, required: true, desc: "Hostname or domain ID"
          project_option
          wait_options

          def call(service:, hostname_or_id:, wait:, timeout:, api_url:, project: nil, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            path = "#{current.service_path(service, project: project)}/domains/#{segment(hostname_or_id)}/verify"
            response = current.request(:post, path)
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end
      end
    end
  end
end
