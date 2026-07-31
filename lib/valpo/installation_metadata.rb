# frozen_string_literal: true

require "json"
require "time"

module Valpo
  class InstallationMetadata
    DEFAULT_PATH = "/var/lib/valpo-updater/installation.json"
    CHANNELS = %w[development preview stable].freeze
    REQUIRED_KEYS = %w[version channel artifact_digest installed_at].freeze

    attr_reader :version, :channel, :artifact_digest, :installed_at

    def self.current
      @current ||= begin
        path = ENV.fetch("VALPO_INSTALLATION_METADATA", DEFAULT_PATH)
        File.file?(path) ? load(path:) : development
      end
    end

    def self.development
      new(
        {
          "version" => Valpo::VERSION,
          "channel" => "development",
          "artifact_digest" => nil,
          "installed_at" => nil
        },
        path: nil
      )
    end

    def self.load(path:)
      data = JSON.parse(File.binread(path))
      raise Valpo::ValidationError, "Installation metadata must contain an object: #{path}" unless data.is_a?(Hash)

      new(data, path:)
    rescue JSON::ParserError => e
      raise Valpo::ValidationError, "Installation metadata is invalid: #{e.message}"
    rescue SystemCallError => e
      raise Valpo::ValidationError, "Cannot read installation metadata #{path}: #{e.message}"
    end

    def initialize(data, path:)
      unknown = data.keys - REQUIRED_KEYS
      missing = REQUIRED_KEYS - data.keys
      unless unknown.empty? && missing.empty?
        details = []
        details << "missing #{missing.sort.join(", ")}" unless missing.empty?
        details << "unknown #{unknown.sort.join(", ")}" unless unknown.empty?
        raise Valpo::ValidationError, "Installation metadata keys are invalid (#{details.join("; ")}): #{path}"
      end

      @version = required_string(data.fetch("version"), "version")
      @channel = required_string(data.fetch("channel"), "channel")
      @artifact_digest = optional_digest(data.fetch("artifact_digest"))
      @installed_at = optional_time(data.fetch("installed_at"))
      validate!
    end

    def to_h
      {version:, channel:, artifact_digest:, installed_at: installed_at&.iso8601}
    end

    private

    def validate!
      raise Valpo::ValidationError, "Installation version does not match Valpo::VERSION" unless version == Valpo::VERSION
      raise Valpo::ValidationError, "Unknown installation channel: #{channel}" unless CHANNELS.include?(channel)
      return if channel == "development" || (artifact_digest && installed_at)

      raise Valpo::ValidationError, "Published installations require artifact_digest and installed_at"
    end

    def required_string(value, name)
      return value if value.is_a?(String) && !value.empty?

      raise Valpo::ValidationError, "Installation #{name} must be a non-empty string"
    end

    def optional_digest(value)
      return nil if value.nil?
      return value if value.is_a?(String) && value.match?(/\Asha256:[0-9a-f]{64}\z/)

      raise Valpo::ValidationError, "Installation artifact_digest must be null or a sha256 digest"
    end

    def optional_time(value)
      return nil if value.nil?
      return Time.iso8601(value).utc if value.is_a?(String)

      raise Valpo::ValidationError, "Installation installed_at must be null or an ISO 8601 timestamp"
    rescue ArgumentError
      raise Valpo::ValidationError, "Installation installed_at must be null or an ISO 8601 timestamp"
    end
  end
end
