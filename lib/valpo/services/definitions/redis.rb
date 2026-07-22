# frozen_string_literal: true

require "securerandom"

module Valpo
  module Services
    module Definitions
      class Redis < Base
        def initialize
          super(
            name: "redis",
            category: :managed,
            description: "Private managed Redis database",
            supported_options: %i[version]
          )
        end

        def versions
          %w[7 8]
        end

        def default_version
          "8"
        end

        def image(version)
          "redis:#{version}-alpine"
        end

        def internal_port
          6379
        end

        def volume_path
          "/data"
        end

        def credentials
          {"password" => SecureRandom.urlsafe_base64(32)}
        end

        def container_environment(_credentials)
          {}
        end

        def command(credentials)
          ["redis-server", "--appendonly", "yes", "--requirepass", credentials.fetch("password")]
        end

        def readiness_command(credentials)
          ["redis-cli", "-a", credentials.fetch("password"), "PING"]
        end

        def binding_environment(config)
          password = config.credentials.fetch("password")
          host = config.internal_host || config.container_name
          port = config.internal_port
          {
            "REDIS_URL" => "redis://:#{password}@#{host}:#{port}/0",
            "REDIS_HOST" => host,
            "REDIS_PORT" => port.to_s,
            "REDIS_PASSWORD" => password
          }
        end
      end
    end
  end
end
