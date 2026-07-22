# frozen_string_literal: true

require "securerandom"

module Valpo
  module Services
    module Definitions
      class Postgres < Base
        def initialize
          super(
            name: "postgres",
            category: :managed,
            description: "Private managed PostgreSQL database",
            supported_options: %i[version]
          )
        end

        def versions
          %w[16 17 18]
        end

        def default_version
          "18"
        end

        def image(version)
          "postgres:#{version}-alpine"
        end

        def internal_port
          5432
        end

        def volume_path
          "/var/lib/postgresql"
        end

        def credentials
          {
            "database" => "valpo_#{SecureRandom.hex(6)}",
            "username" => "valpo_#{SecureRandom.hex(6)}",
            "password" => SecureRandom.urlsafe_base64(32)
          }
        end

        def container_environment(credentials)
          {
            "POSTGRES_DB" => credentials.fetch("database"),
            "POSTGRES_USER" => credentials.fetch("username"),
            "POSTGRES_PASSWORD" => credentials.fetch("password")
          }
        end

        def command(_credentials)
          []
        end

        def readiness_command(credentials)
          ["pg_isready", "-U", credentials.fetch("username"), "-d", credentials.fetch("database")]
        end

        def binding_environment(config)
          credentials = config.credentials
          host = config.internal_host || config.container_name
          port = config.internal_port
          database = credentials.fetch("database")
          username = credentials.fetch("username")
          password = credentials.fetch("password")
          {
            "DATABASE_URL" => "postgres://#{username}:#{password}@#{host}:#{port}/#{database}",
            "PGHOST" => host,
            "PGPORT" => port.to_s,
            "PGDATABASE" => database,
            "PGUSER" => username,
            "PGPASSWORD" => password
          }
        end
      end
    end
  end
end
