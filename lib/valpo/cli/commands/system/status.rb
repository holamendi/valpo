# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module System
        class Status < BaseCommand
          desc "Check API health and client/server version compatibility"

          def call(api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            current = context(api_url:, json:)
            health = current.request(:get, "/health")
            server_version = health.fetch("version")
            server_api_version = health.fetch("api_version")
            compatible = server_api_version == Valpo::API_VERSION
            unless compatible
              current.presenter.err.puts \
                "Warning: client API #{Valpo::API_VERSION} is not compatible with server API #{server_api_version}"
            end
            current.presenter.system_status(
              "status" => health["ok"] ? "ok" : "unhealthy",
              "client_version" => Valpo::VERSION,
              "server_version" => server_version,
              "client_api_version" => Valpo::API_VERSION,
              "server_api_version" => server_api_version,
              "schema_version" => health.fetch("schema_version"),
              "schema_target" => health.fetch("schema_target"),
              "config_schema" => health.fetch("config_schema"),
              "host_profile" => health.fetch("host_profile"),
              "channel" => health.fetch("channel"),
              "artifact_digest" => health["artifact_digest"],
              "compatible" => compatible
            )
          end
        end
      end
    end
  end
end
