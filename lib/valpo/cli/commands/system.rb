# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module System
        class Status < BaseCommand
          desc "Check API health and client/server version compatibility"

          def call(api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            health = current.request(:get, "/health")
            server_version = health.fetch("version")
            compatible = server_version == Valpo::VERSION
            current.presenter.err.puts "Warning: client #{Valpo::VERSION} does not match server #{server_version}" unless compatible
            current.presenter.system_status(
              "status" => health["ok"] ? "ok" : "unhealthy",
              "client_version" => Valpo::VERSION,
              "server_version" => server_version,
              "compatible" => compatible
            )
          end
        end

        class Repair < BaseCommand
          desc "Regenerate runtime state from Valpo records"
          wait_options

          def call(wait:, timeout:, api_url:, config: nil, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url: api_url, config: config, json: json)
            response = current.request(:post, "/system/repair")
            current.presenter.operation(current.finish_operation(response, wait: wait, timeout: timeout))
          end
        end
      end
    end
  end
end
