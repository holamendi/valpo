# frozen_string_literal: true

require "yaml"

module Valpo
  class Config
    CURRENT_SCHEMA = 1
    DEFAULT_ENV = "development"
    DEFAULT_API_PORT = 7092
    DEFAULT_WORKER_POLL_INTERVAL = 2
    DEFAULT_APP_PORT_START = 20_000
    DEFAULT_APP_PORT_END = 29_999
    DEFAULT_HEALTHCHECK_TIMEOUT = 30
    DEFAULT_DEPLOY_DRAIN_DELAY = 0
    DEFAULT_BUILD_TIMEOUT = 1_800
    DEFAULT_BUILD_LOG_LIMIT = 16_777_216
    DEFAULT_BUILDPACK_BUILDER = "heroku/builder@sha256:e0d2453e68106a8000da70780f631e888ca61a515ea9921a26a1f7391964908a"
    DEFAULT_IMAGE_RETENTION_COUNT = 3
    DEFAULT_STORAGE_CLEANUP_GRACE_PERIOD = 86_400
    DEFAULT_BUILD_CACHE_RETENTION = 2_592_000
    DEFAULT_JOB_RETENTION = 2_592_000
    DEFAULT_CONTAINER_LOG_MAX_SIZE = "10m"
    DEFAULT_CONTAINER_LOG_MAX_FILES = 3
    KEYS = %w[
      config_schema
      database_path
      encryption_key_path
      api_host
      api_port
      caddy_config_path
      caddy_reload_config_path
      docker_network
      worker_poll_interval
      app_port_start
      app_port_end
      healthcheck_timeout
      deploy_drain_delay
      build_timeout
      build_log_limit
      buildpack_builder
      image_retention_count
      storage_cleanup_grace_period
      build_cache_retention
      job_retention
      container_log_max_size
      container_log_max_files
    ].freeze

    attr_reader :env,
      :root,
      :config_schema,
      :database_path,
      :encryption_key_path,
      :api_host,
      :api_port,
      :caddy_config_path,
      :caddy_reload_config_path,
      :docker_network,
      :worker_poll_interval,
      :app_port_start,
      :app_port_end,
      :healthcheck_timeout,
      :deploy_drain_delay,
      :build_timeout,
      :build_log_limit,
      :buildpack_builder,
      :image_retention_count,
      :storage_cleanup_grace_period,
      :build_cache_retention,
      :job_retention,
      :container_log_max_size,
      :container_log_max_files

    def self.load(path: ENV["VALPO_CONFIG"], env: ENV.fetch("VALPO_ENV", DEFAULT_ENV))
      env = env.to_s
      data = path.nil? ? {} : load_file(path)
      env_data = path.nil? ? {} : environment_data(data, env)
      reject_unknown_keys!(env_data)

      new(
        env:,
        root: Valpo.root,
        config_schema: integer_value(env_data, "config_schema", nil, CURRENT_SCHEMA),
        database_path: value(env_data, "database_path", ENV["VALPO_DATABASE_PATH"], default_database_path(env)),
        encryption_key_path: value(env_data, "encryption_key_path", ENV["VALPO_ENCRYPTION_KEY_PATH"], nil),
        api_host: value(env_data, "api_host", ENV["VALPO_API_HOST"], "127.0.0.1"),
        api_port: integer_value(env_data, "api_port", ENV["VALPO_API_PORT"], DEFAULT_API_PORT),
        caddy_config_path: value(env_data, "caddy_config_path", ENV["VALPO_CADDY_CONFIG_PATH"], default_caddy_config_path(env)),
        caddy_reload_config_path: value(env_data, "caddy_reload_config_path", ENV["VALPO_CADDY_RELOAD_CONFIG_PATH"], nil),
        docker_network: value(env_data, "docker_network", ENV["VALPO_DOCKER_NETWORK"], "valpo"),
        worker_poll_interval: float_value(env_data, "worker_poll_interval", ENV["VALPO_WORKER_POLL_INTERVAL"], DEFAULT_WORKER_POLL_INTERVAL),
        app_port_start: integer_value(env_data, "app_port_start", ENV["VALPO_APP_PORT_START"], DEFAULT_APP_PORT_START),
        app_port_end: integer_value(env_data, "app_port_end", ENV["VALPO_APP_PORT_END"], DEFAULT_APP_PORT_END),
        healthcheck_timeout: integer_value(env_data, "healthcheck_timeout", ENV["VALPO_HEALTHCHECK_TIMEOUT"], DEFAULT_HEALTHCHECK_TIMEOUT),
        deploy_drain_delay: float_value(env_data, "deploy_drain_delay", ENV["VALPO_DEPLOY_DRAIN_DELAY"], DEFAULT_DEPLOY_DRAIN_DELAY),
        build_timeout: integer_value(env_data, "build_timeout", ENV["VALPO_BUILD_TIMEOUT"], DEFAULT_BUILD_TIMEOUT),
        build_log_limit: integer_value(env_data, "build_log_limit", ENV["VALPO_BUILD_LOG_LIMIT"], DEFAULT_BUILD_LOG_LIMIT),
        buildpack_builder: value(env_data, "buildpack_builder", ENV["VALPO_BUILDPACK_BUILDER"], DEFAULT_BUILDPACK_BUILDER),
        image_retention_count: integer_value(env_data, "image_retention_count", ENV["VALPO_IMAGE_RETENTION_COUNT"], DEFAULT_IMAGE_RETENTION_COUNT),
        storage_cleanup_grace_period: integer_value(
          env_data,
          "storage_cleanup_grace_period",
          ENV["VALPO_STORAGE_CLEANUP_GRACE_PERIOD"],
          DEFAULT_STORAGE_CLEANUP_GRACE_PERIOD
        ),
        build_cache_retention: integer_value(env_data, "build_cache_retention", ENV["VALPO_BUILD_CACHE_RETENTION"], DEFAULT_BUILD_CACHE_RETENTION),
        job_retention: integer_value(env_data, "job_retention", ENV["VALPO_JOB_RETENTION"], DEFAULT_JOB_RETENTION),
        container_log_max_size: value(env_data, "container_log_max_size", ENV["VALPO_CONTAINER_LOG_MAX_SIZE"], DEFAULT_CONTAINER_LOG_MAX_SIZE),
        container_log_max_files: integer_value(
          env_data,
          "container_log_max_files",
          ENV["VALPO_CONTAINER_LOG_MAX_FILES"],
          DEFAULT_CONTAINER_LOG_MAX_FILES
        )
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

    def initialize(
      env:,
      root:,
      database_path:,
      api_host:,
      api_port:,
      caddy_config_path:,
      docker_network:,
      worker_poll_interval:,
      app_port_start:,
      app_port_end:,
      healthcheck_timeout:,
      deploy_drain_delay:,
      config_schema: CURRENT_SCHEMA,
      encryption_key_path: nil,
      caddy_reload_config_path: nil,
      build_timeout: DEFAULT_BUILD_TIMEOUT,
      build_log_limit: DEFAULT_BUILD_LOG_LIMIT,
      buildpack_builder: DEFAULT_BUILDPACK_BUILDER,
      image_retention_count: DEFAULT_IMAGE_RETENTION_COUNT,
      storage_cleanup_grace_period: DEFAULT_STORAGE_CLEANUP_GRACE_PERIOD,
      build_cache_retention: DEFAULT_BUILD_CACHE_RETENTION,
      job_retention: DEFAULT_JOB_RETENTION,
      container_log_max_size: DEFAULT_CONTAINER_LOG_MAX_SIZE,
      container_log_max_files: DEFAULT_CONTAINER_LOG_MAX_FILES
    )
      @env = required_string(env, "env")
      @root = required_string(root, "root")
      @config_schema = config_schema
      @database_path = expand_path(database_path)
      @encryption_key_path = encryption_key_path ? expand_path(encryption_key_path) : File.join(File.dirname(@database_path), "secrets", "master.key")
      @api_host = required_string(api_host, "api_host")
      @api_port = api_port
      @caddy_config_path = expand_path(caddy_config_path)
      @caddy_reload_config_path = caddy_reload_config_path ? expand_path(caddy_reload_config_path) : @caddy_config_path
      @docker_network = required_string(docker_network, "docker_network")
      @worker_poll_interval = worker_poll_interval
      @app_port_start = app_port_start
      @app_port_end = app_port_end
      @healthcheck_timeout = healthcheck_timeout
      @deploy_drain_delay = deploy_drain_delay
      @build_timeout = build_timeout
      @build_log_limit = build_log_limit
      @buildpack_builder = required_string(buildpack_builder, "buildpack_builder")
      @image_retention_count = image_retention_count
      @storage_cleanup_grace_period = storage_cleanup_grace_period
      @build_cache_retention = build_cache_retention
      @job_retention = job_retention
      @container_log_max_size = required_string(container_log_max_size, "container_log_max_size")
      @container_log_max_files = container_log_max_files
      validate!
    end

    def validate!
      unless @config_schema == CURRENT_SCHEMA
        raise Valpo::ValidationError,
          "config_schema #{@config_schema} is not supported; expected #{CURRENT_SCHEMA}"
      end
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
      raise Valpo::ValidationError, "build_log_limit must be greater than 0" unless @build_log_limit.positive?
      raise Valpo::ValidationError, "image_retention_count must be greater than 0" unless @image_retention_count.positive?
      unless @storage_cleanup_grace_period >= 0
        raise Valpo::ValidationError, "storage_cleanup_grace_period must be greater than or equal to 0"
      end
      raise Valpo::ValidationError, "build_cache_retention must be greater than 0" unless @build_cache_retention.positive?
      raise Valpo::ValidationError, "job_retention must be greater than 0" unless @job_retention.positive?
      unless @container_log_max_size.match?(/\A[1-9]\d*[kmg]\z/i)
        raise Valpo::ValidationError, "container_log_max_size must be a positive size ending in k, m, or g"
      end
      unless @container_log_max_files.positive?
        raise Valpo::ValidationError, "container_log_max_files must be greater than 0"
      end
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
