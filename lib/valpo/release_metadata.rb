# frozen_string_literal: true

require "json"

module Valpo
  class ReleaseMetadata
    PATH = File.join(Valpo.root, "release.json")
    REQUIRED_KEYS = %w[
      version
      api_version
      schema_min
      schema_target
      schema_max
      config_schema
      host_profile
    ].freeze

    attr_reader :version,
      :api_version,
      :schema_min,
      :schema_target,
      :schema_max,
      :config_schema,
      :host_profile

    def self.current
      @current ||= load
    end

    def self.load(path: PATH)
      data = JSON.parse(File.binread(path))
      raise Valpo::ValidationError, "Release metadata must contain an object: #{path}" unless data.is_a?(Hash)

      new(data, path:)
    rescue JSON::ParserError => e
      raise Valpo::ValidationError, "Release metadata is invalid: #{e.message}"
    rescue SystemCallError => e
      raise Valpo::ValidationError, "Cannot read release metadata #{path}: #{e.message}"
    end

    def initialize(data, path: PATH)
      unknown = data.keys - REQUIRED_KEYS
      missing = REQUIRED_KEYS - data.keys
      unless unknown.empty? && missing.empty?
        details = []
        details << "missing #{missing.sort.join(", ")}" unless missing.empty?
        details << "unknown #{unknown.sort.join(", ")}" unless unknown.empty?
        raise Valpo::ValidationError, "Release metadata keys are invalid (#{details.join("; ")}): #{path}"
      end

      @version = required_string(data.fetch("version"), "version")
      @api_version = positive_integer(data.fetch("api_version"), "api_version")
      @schema_min = positive_integer(data.fetch("schema_min"), "schema_min")
      @schema_target = positive_integer(data.fetch("schema_target"), "schema_target")
      @schema_max = positive_integer(data.fetch("schema_max"), "schema_max")
      @config_schema = positive_integer(data.fetch("config_schema"), "config_schema")
      @host_profile = positive_integer(data.fetch("host_profile"), "host_profile")
      validate!
    end

    def to_h
      {
        version:,
        api_version:,
        schema_min:,
        schema_target:,
        schema_max:,
        config_schema:,
        host_profile:
      }
    end

    def validate_database!(db: Valpo::Database.connection)
      current = Valpo::SchemaInfo.current(db:)
      return current if current == schema_target

      raise Valpo::ValidationError,
        "Database schema #{current} does not match release target #{schema_target}; run migrations before boot"
    end

    private

    def validate!
      raise Valpo::ValidationError, "Release version does not match Valpo::VERSION" unless version == Valpo::VERSION
      raise Valpo::ValidationError, "API version does not match Valpo::API_VERSION" unless api_version == Valpo::API_VERSION
      unless schema_target.between?(schema_min, schema_max)
        raise Valpo::ValidationError, "Release schema versions must satisfy min <= target <= max"
      end
      unless schema_target == Valpo::SchemaInfo.latest
        raise Valpo::ValidationError,
          "Release schema target #{schema_target} does not match latest migration #{Valpo::SchemaInfo.latest}"
      end
      unless config_schema == Valpo::Config::CURRENT_SCHEMA
        raise Valpo::ValidationError, "Release config schema does not match Valpo::Config::CURRENT_SCHEMA"
      end
    end

    def required_string(value, name)
      return value if value.is_a?(String) && !value.empty?

      raise Valpo::ValidationError, "Release #{name} must be a non-empty string"
    end

    def positive_integer(value, name)
      return value if value.is_a?(Integer) && value.positive?

      raise Valpo::ValidationError, "Release #{name} must be a positive integer"
    end
  end
end
