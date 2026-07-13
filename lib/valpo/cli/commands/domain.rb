# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Domain
        class List < BaseCommand
          desc "List domains attached to a web service"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"

          def call(service:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            current.presenter.domains(current.request(:get, "#{current.service_path(service)}/domains"))
          end
        end

        class Add < BaseCommand
          desc "Attach a hostname to a web service"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          argument :hostname, required: true, desc: "DNS hostname"
          wait_options

          def call(service:, hostname:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "#{current.service_path(service)}/domains", {"hostname" => hostname})
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end

        class Remove < BaseCommand
          desc "Remove a hostname from a web service"
          argument :service, required: true, desc: "PROJECT/NAME or service ID"
          argument :hostname_or_id, required: true, desc: "Hostname or domain ID"
          wait_options

          def call(service:, hostname_or_id:, wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:delete, "#{current.service_path(service)}/domains/#{segment(hostname_or_id)}")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end
      end
    end
  end
end
