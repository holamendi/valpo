# frozen_string_literal: true

require "yaml"

module Valpo
  class Config
    DEFAULT_ENV = "development"
    DEFAULT_API_PORT = 7092
    DEFAULT_WORKER_POLL_INTERVAL = 2

    attr_reader :env,
                :root,
                :database_path,
                :api_host,
                :api_port,
                :caddy_config_path,
                :docker_network,
                :worker_poll_interval

    def self.load(path: ENV["VALPO_CONFIG"], env: ENV.fetch("VALPO_ENV", DEFAULT_ENV))
      data = path && File.exist?(path) ? YAML.safe_load_file(path, aliases: false) || {} : {}
      env_data = data.fetch(env, data)

      new(
        env: env,
        root: Valpo.root,
        database_path: value(env_data, "database_path", ENV["VALPO_DATABASE_PATH"], default_database_path(env)),
        api_host: value(env_data, "api_host", ENV["VALPO_API_HOST"], "127.0.0.1"),
        api_port: Integer(value(env_data, "api_port", ENV["VALPO_API_PORT"], DEFAULT_API_PORT)),
        caddy_config_path: value(env_data, "caddy_config_path", ENV["VALPO_CADDY_CONFIG_PATH"], default_caddy_config_path(env)),
        docker_network: value(env_data, "docker_network", ENV["VALPO_DOCKER_NETWORK"], "valpo"),
        worker_poll_interval: Float(value(env_data, "worker_poll_interval", ENV["VALPO_WORKER_POLL_INTERVAL"], DEFAULT_WORKER_POLL_INTERVAL))
      )
    end

    def self.default_database_path(env)
      File.join(Valpo.root, "tmp", "valpo-#{env}.sqlite3")
    end

    def self.default_caddy_config_path(env)
      File.join(Valpo.root, "tmp", "Caddyfile.#{env}")
    end

    def self.value(data, key, env_value, fallback)
      env_value || data[key] || data[key.to_sym] || fallback
    end
    private_class_method :value

    def initialize(env:, root:, database_path:, api_host:, api_port:, caddy_config_path:, docker_network:, worker_poll_interval:)
      @env = env
      @root = root
      @database_path = expand_path(database_path)
      @api_host = api_host
      @api_port = api_port
      @caddy_config_path = expand_path(caddy_config_path)
      @docker_network = docker_network
      @worker_poll_interval = worker_poll_interval
    end

    private

    def expand_path(path)
      return path if path.start_with?("/")

      File.expand_path(path, root)
    end
  end
end
