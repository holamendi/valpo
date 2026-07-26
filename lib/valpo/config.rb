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
    DEFAULT_BUILDPACK_BUILDER = "paketobuildpacks/builder-jammy-base@sha256:7510725172c8b2f1a7bce82b694e2af9599d5e2d97528c140eaeb81c569c21df"
    KEYS = %w[
      database_path
      api_host
      api_port
      api_token
      github_token_path
      github_app_credentials_path
      caddy_config_path
      caddy_reload_config_path
      docker_network
      worker_poll_interval
      app_port_start
      app_port_end
      healthcheck_timeout
      deploy_drain_delay
      build_timeout
      buildpack_builder
    ].freeze

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
      env = env.to_s
      data = path.nil? ? {} : load_file(path)
      env_data = path.nil? ? {} : environment_data(data, env)
      reject_unknown_keys!(env_data)

      new(
        env:,
        root: Valpo.root,
        database_path: value(env_data, "database_path", ENV["VALPO_DATABASE_PATH"], default_database_path(env)),
        api_host: value(env_data, "api_host", ENV["VALPO_API_HOST"], "127.0.0.1"),
        api_port: integer_value(env_data, "api_port", ENV["VALPO_API_PORT"], DEFAULT_API_PORT),
        api_token: blank_to_nil(value(env_data, "api_token", ENV["VALPO_API_TOKEN"], nil)),
        github_token_path: value(env_data, "github_token_path", nil, nil),
        github_app_credentials_path: value(env_data, "github_app_credentials_path", nil, nil),
        caddy_config_path: value(env_data, "caddy_config_path", ENV["VALPO_CADDY_CONFIG_PATH"], default_caddy_config_path(env)),
        caddy_reload_config_path: value(env_data, "caddy_reload_config_path", ENV["VALPO_CADDY_RELOAD_CONFIG_PATH"], nil),
        docker_network: value(env_data, "docker_network", ENV["VALPO_DOCKER_NETWORK"], "valpo"),
        worker_poll_interval: float_value(env_data, "worker_poll_interval", ENV["VALPO_WORKER_POLL_INTERVAL"], DEFAULT_WORKER_POLL_INTERVAL),
        app_port_start: integer_value(env_data, "app_port_start", ENV["VALPO_APP_PORT_START"], DEFAULT_APP_PORT_START),
        app_port_end: integer_value(env_data, "app_port_end", ENV["VALPO_APP_PORT_END"], DEFAULT_APP_PORT_END),
        healthcheck_timeout: integer_value(env_data, "healthcheck_timeout", ENV["VALPO_HEALTHCHECK_TIMEOUT"], DEFAULT_HEALTHCHECK_TIMEOUT),
        deploy_drain_delay: float_value(env_data, "deploy_drain_delay", ENV["VALPO_DEPLOY_DRAIN_DELAY"], DEFAULT_DEPLOY_DRAIN_DELAY),
        build_timeout: integer_value(env_data, "build_timeout", ENV["VALPO_BUILD_TIMEOUT"], DEFAULT_BUILD_TIMEOUT),
        buildpack_builder: value(env_data, "buildpack_builder", ENV["VALPO_BUILDPACK_BUILDER"], DEFAULT_BUILDPACK_BUILDER)
      )
    end

    def self.load_file(path)
      raise Valpo::ValidationError, "Configuration file does not exist: #{path}" unless File.file?(path)
      raise Valpo::ValidationError, "Configuration file is not readable: #{path}" unless File.readable?(path)

      data = YAML.safe_load_file(path, aliases: false)
      raise Valpo::ValidationError, "Configuration file must contain a mapping: #{path}" unless data.is_a?(Hash)

      stringify_keys(data)
    rescue Psych::Exception => e
      raise Valpo::ValidationError, "Configuration file is invalid: #{e.message}"
    rescue SystemCallError => e
      raise Valpo::ValidationError, "Cannot read configuration file #{path}: #{e.message}"
    end
    private_class_method :load_file

    def self.environment_data(data, env)
      top_level_keys = data.keys
      setting_keys = top_level_keys & KEYS
      if setting_keys.any?
        unexpected = top_level_keys - KEYS
        unless unexpected.empty?
          raise Valpo::ValidationError,
            "Configuration cannot mix settings with environments: #{unexpected.sort.join(", ")}"
        end
        return data
      end

      unless data.values.all? { it.is_a?(Hash) }
        raise Valpo::ValidationError, "Unknown configuration keys: #{top_level_keys.sort.join(", ")}"
      end

      data.each do |name, settings|
        reject_unknown_keys!(settings)
      end

      selected = data[env]
      raise Valpo::ValidationError, "Configuration environment is missing: #{env}" unless selected

      selected
    end
    private_class_method :environment_data

    def self.reject_unknown_keys!(data)
      unknown = data.keys - KEYS
      return if unknown.empty?

      raise Valpo::ValidationError, "Unknown configuration keys: #{unknown.sort.join(", ")}"
    end
    private_class_method :reject_unknown_keys!

    def self.stringify_keys(data)
      data.to_h { |key, value| [key.to_s, value.is_a?(Hash) ? stringify_keys(value) : value] }
    end
    private_class_method :stringify_keys

    def self.default_database_path(env)
      File.join(Valpo.root, "tmp", "valpo-#{env}.sqlite3")
    end

    def self.default_caddy_config_path(env)
      File.join(Valpo.root, "tmp", "Caddyfile.#{env}")
    end

    def self.value(data, key, env_value, fallback)
      return env_value unless env_value.nil?
      return data[key] if data.key?(key)

      fallback
    end
    private_class_method :value

    def self.integer_value(data, key, env_value, fallback)
      raw = value(data, key, env_value, fallback)
      case raw
      when Integer
        raw
      when String
        Integer(raw, 10)
      else
        raise Valpo::ValidationError, "#{key} must be an integer"
      end
    rescue ArgumentError, TypeError
      raise Valpo::ValidationError, "#{key} must be an integer"
    end
    private_class_method :integer_value

    def self.float_value(data, key, env_value, fallback)
      raw = value(data, key, env_value, fallback)
      case raw
      when Integer, Float
        raw.to_f
      when String
        Float(raw)
      else
        raise Valpo::ValidationError, "#{key} must be a number"
      end
    rescue ArgumentError, TypeError
      raise Valpo::ValidationError, "#{key} must be a number"
    end
    private_class_method :float_value

    def self.blank_to_nil(value)
      return nil if value.nil?
      raise Valpo::ValidationError, "api_token must be a string" unless value.is_a?(String)

      value.strip.empty? ? nil : value
    end
    private_class_method :blank_to_nil

    def initialize(env:, root:, database_path:, api_host:, api_port:, caddy_config_path:, docker_network:, worker_poll_interval:, app_port_start:, app_port_end:, healthcheck_timeout:, deploy_drain_delay:, api_token: nil, github_token_path: nil, github_app_credentials_path: nil, caddy_reload_config_path: nil, build_timeout: DEFAULT_BUILD_TIMEOUT, buildpack_builder: DEFAULT_BUILDPACK_BUILDER)
      @env = required_string(env, "env")
      @root = required_string(root, "root")
      @database_path = expand_path(database_path)
      @api_host = required_string(api_host, "api_host")
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
      @docker_network = required_string(docker_network, "docker_network")
      @worker_poll_interval = worker_poll_interval
      @app_port_start = app_port_start
      @app_port_end = app_port_end
      @healthcheck_timeout = healthcheck_timeout
      @deploy_drain_delay = deploy_drain_delay
      @build_timeout = build_timeout
      @buildpack_builder = required_string(buildpack_builder, "buildpack_builder")
      validate!
    end

    def validate!
      unless (1..65_535).cover?(@api_port)
        raise Valpo::ValidationError, "api_port must be between 1 and 65535"
      end
      unless @worker_poll_interval.finite? && @worker_poll_interval.positive?
        raise Valpo::ValidationError, "worker_poll_interval must be greater than 0"
      end
      unless (1..65_535).cover?(@app_port_start) && (1..65_535).cover?(@app_port_end)
        raise Valpo::ValidationError, "app ports must be between 1 and 65535"
      end
      if @app_port_start > @app_port_end
        raise Valpo::ValidationError, "app_port_start must not be greater than app_port_end"
      end
      raise Valpo::ValidationError, "healthcheck_timeout must be greater than 0" unless @healthcheck_timeout.positive?
      unless @deploy_drain_delay.finite? && @deploy_drain_delay >= 0
        raise Valpo::ValidationError, "deploy_drain_delay must be greater than or equal to 0"
      end
      raise Valpo::ValidationError, "build_timeout must be greater than 0" unless @build_timeout.positive?
    end

    def github_token
      Valpo::Credentials::FileStore.new(github_token_path).read
    end

    private

    def expand_path(path)
      path = required_string(path, "path")
      return path if path.start_with?("/")

      File.expand_path(path, root)
    end

    def required_string(value, name)
      unless value.is_a?(String) && !value.strip.empty?
        raise Valpo::ValidationError, "#{name} must be a non-empty string"
      end

      value
    end
  end
end
