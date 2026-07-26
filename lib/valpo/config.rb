# frozen_string_literal: true

require "yaml"

module Valpo
  class Config
    DEFAULT_ENV = "development"
    DEFAULT_API_PORT = 7092
    DEFAULT_WORKER_POLL_INTERVAL = 2
    DEFAULT_APP_PORT_START = 20_000
    DEFAULT_APP_PORT_END = 29_999
    DEFAULT_HEALTHCHECK_TIMEOUT = 30
    DEFAULT_DEPLOY_DRAIN_DELAY = 0
    DEFAULT_BUILD_TIMEOUT = 1_800
    DEFAULT_BUILDPACK_BUILDER = "paketobuildpacks/ubuntu-noble-builder@sha256:6576792807752dfc227d0df115c99b0a77d97ddb71b4d6c757e99630c60db019"

    attr_reader :env,
      :root,
      :database_path,
      :api_host,
      :api_port,
      :api_token,
      :github_token_path,
      :github_app_credentials_path,
      :caddy_config_path,
      :caddy_reload_config_path,
      :docker_network,
      :worker_poll_interval,
      :app_port_start,
      :app_port_end,
      :healthcheck_timeout,
      :deploy_drain_delay,
      :build_timeout,
      :buildpack_builder

    def self.load(path: ENV["VALPO_CONFIG"], env: ENV.fetch("VALPO_ENV", DEFAULT_ENV))
      data = (path && File.exist?(path)) ? YAML.safe_load_file(path, aliases: false) || {} : {}
      env_data = data.fetch(env, data)

      new(
        env:,
        root: Valpo.root,
        database_path: value(env_data, "database_path", ENV["VALPO_DATABASE_PATH"], default_database_path(env)),
        api_host: value(env_data, "api_host", ENV["VALPO_API_HOST"], "127.0.0.1"),
        api_port: Integer(value(env_data, "api_port", ENV["VALPO_API_PORT"], DEFAULT_API_PORT)),
        api_token: blank_to_nil(value(env_data, "api_token", ENV["VALPO_API_TOKEN"], nil)),
        github_token_path: value(env_data, "github_token_path", nil, nil),
        github_app_credentials_path: value(env_data, "github_app_credentials_path", nil, nil),
        caddy_config_path: value(env_data, "caddy_config_path", ENV["VALPO_CADDY_CONFIG_PATH"], default_caddy_config_path(env)),
        caddy_reload_config_path: value(env_data, "caddy_reload_config_path", ENV["VALPO_CADDY_RELOAD_CONFIG_PATH"], nil),
        docker_network: value(env_data, "docker_network", ENV["VALPO_DOCKER_NETWORK"], "valpo"),
        worker_poll_interval: Float(value(env_data, "worker_poll_interval", ENV["VALPO_WORKER_POLL_INTERVAL"], DEFAULT_WORKER_POLL_INTERVAL)),
        app_port_start: Integer(value(env_data, "app_port_start", ENV["VALPO_APP_PORT_START"], DEFAULT_APP_PORT_START)),
        app_port_end: Integer(value(env_data, "app_port_end", ENV["VALPO_APP_PORT_END"], DEFAULT_APP_PORT_END)),
        healthcheck_timeout: Integer(value(env_data, "healthcheck_timeout", ENV["VALPO_HEALTHCHECK_TIMEOUT"], DEFAULT_HEALTHCHECK_TIMEOUT)),
        deploy_drain_delay: Float(value(env_data, "deploy_drain_delay", ENV["VALPO_DEPLOY_DRAIN_DELAY"], DEFAULT_DEPLOY_DRAIN_DELAY)),
        build_timeout: Integer(value(env_data, "build_timeout", ENV["VALPO_BUILD_TIMEOUT"], DEFAULT_BUILD_TIMEOUT)),
        buildpack_builder: value(env_data, "buildpack_builder", ENV["VALPO_BUILDPACK_BUILDER"], DEFAULT_BUILDPACK_BUILDER)
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

    def self.blank_to_nil(value)
      (value.nil? || value.to_s.strip.empty?) ? nil : value.to_s
    end
    private_class_method :blank_to_nil

    def initialize(env:, root:, database_path:, api_host:, api_port:, caddy_config_path:, docker_network:, worker_poll_interval:, app_port_start:, app_port_end:, healthcheck_timeout:, deploy_drain_delay:, api_token: nil, github_token_path: nil, github_app_credentials_path: nil, caddy_reload_config_path: nil, build_timeout: DEFAULT_BUILD_TIMEOUT, buildpack_builder: DEFAULT_BUILDPACK_BUILDER)
      @env = env
      @root = root
      @database_path = expand_path(database_path)
      @api_host = api_host
      @api_port = api_port
      @api_token = self.class.send(:blank_to_nil, api_token)
      @github_token_path = github_token_path ? expand_path(github_token_path) : File.join(File.dirname(@database_path), "secrets", "github-token")
      @github_app_credentials_path = if github_app_credentials_path
        expand_path(github_app_credentials_path)
      else
        File.join(File.dirname(@database_path), "secrets", "github-app.json")
      end
      @caddy_config_path = expand_path(caddy_config_path)
      @caddy_reload_config_path = caddy_reload_config_path ? expand_path(caddy_reload_config_path) : @caddy_config_path
      @docker_network = docker_network
      @worker_poll_interval = worker_poll_interval
      @app_port_start = app_port_start
      @app_port_end = app_port_end
      @healthcheck_timeout = healthcheck_timeout
      @deploy_drain_delay = deploy_drain_delay
      @build_timeout = build_timeout
      @buildpack_builder = buildpack_builder.to_s.strip
      raise Valpo::ValidationError, "build_timeout must be greater than 0" unless @build_timeout.positive?
      raise Valpo::ValidationError, "buildpack_builder must be a non-empty image reference" if @buildpack_builder.empty?
    end

    def github_token
      Valpo::Credentials::FileStore.new(github_token_path).read
    end

    private

    def expand_path(path)
      return path if path.start_with?("/")

      File.expand_path(path, root)
    end
  end
end
