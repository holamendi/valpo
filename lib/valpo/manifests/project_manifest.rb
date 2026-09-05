# frozen_string_literal: true

require "digest"
require "json"
require "toml-rb"

module Valpo
  module Manifests
    class ProjectManifest
      ROOT_KEYS = %w[schema project sources builds services].freeze
      PROJECT_KEYS = %w[name].freeze
      SOURCE_KEYS = %w[provider repository ref auto_deploy].freeze
      BUILD_KEYS = %w[source strategy dockerfile context builder buildpacks].freeze
      APP_KEYS = %w[type build command port healthcheck depends_on].freeze
      MANAGED_KEYS = %w[type version].freeze

      def self.parse(content)
        new(content).parse
      end

      def initialize(content)
        @content = content.to_s
      end

      def parse
        raw = TomlRB.parse(content)
        validate_keys!(raw, ROOT_KEYS, "root")
        raise Valpo::ValidationError, "valpo.toml schema must be 1" unless raw["schema"] == 1

        project = required_table(raw, "project")
        validate_keys!(project, PROJECT_KEYS, "project")
        validate_name!(required_string(project, "name"), "project.name")
        normalized = {
          "schema" => 1,
          "project" => {"name" => project.fetch("name")},
          "sources" => normalize_sources(raw.fetch("sources", {})),
          "builds" => normalize_builds(raw.fetch("builds", {})),
          "services" => normalize_services(raw.fetch("services", {}))
        }
        validate_references!(normalized)
        normalized["digest"] = Digest::SHA256.hexdigest(JSON.generate(normalized))
        normalized
      rescue TomlRB::ParseError => e
        raise Valpo::ValidationError, "Invalid valpo.toml: #{e.message}"
      end

      private

      attr_reader :content

      def normalize_sources(sources)
        validate_table!(sources, "sources")
        sources.sort.to_h do |name, config|
          validate_name!(name, "source name")
          validate_table!(config, "sources.#{name}")
          validate_keys!(config, SOURCE_KEYS, "sources.#{name}")
          provider = required_string(config, "provider").downcase
          unless Valpo::Source::PROVIDERS.include?(provider)
            raise Valpo::ValidationError, "Unsupported source provider: #{provider}"
          end
          repository = required_string(config, "repository")
          if provider == "github" && !repository.match?(Valpo::Sources::GitHub::REPOSITORY_PATTERN)
            raise Valpo::ValidationError, "sources.#{name}.repository must be a GitHub owner/repository name"
          end
          [name, {
            "provider" => provider,
            "repository" => repository,
            "ref" => Valpo::Sources::Validation.github_ref(optional_string(config, "ref") || "HEAD"),
            "auto_deploy" => boolean(config, "auto_deploy", false)
          }]
        end
      end

      def normalize_builds(builds)
        validate_table!(builds, "builds")
        builds.sort.to_h do |name, config|
          validate_name!(name, "build name")
          validate_table!(config, "builds.#{name}")
          validate_keys!(config, BUILD_KEYS, "builds.#{name}")
          strategy = optional_string(config, "strategy")&.downcase
          strategy ||= config.key?("dockerfile") ? "dockerfile" : "auto"
          unless Valpo::Builds::STRATEGIES.include?(strategy)
            raise Valpo::ValidationError, "Unsupported build strategy: #{strategy}"
          end
          if strategy != "dockerfile" && config.key?("dockerfile")
            raise Valpo::ValidationError, "builds.#{name}.dockerfile is only valid for dockerfile builds"
          end
          builder = optional_string(config, "builder")
          buildpacks = config["buildpacks"]
          Valpo::Builds::BuildpackOptions.validate!(strategy:, builder:, buildpacks:)
          [name, {
            "builder" => builder,
            "buildpacks" => buildpacks,
            "source" => required_string(config, "source"),
            "strategy" => strategy,
            "dockerfile" => (optional_relative_path(config, "dockerfile") || "Dockerfile" if strategy == "dockerfile"),
            "context" => optional_relative_path(config, "context") || "."
          }]
        end
      end

      def normalize_services(services)
        validate_table!(services, "services")
        services.sort.to_h do |name, config|
          validate_name!(name, "service name")
          validate_table!(config, "services.#{name}")
          type = Valpo::Services::Registry.normalize_type(required_string(config, "type"))
          Valpo::Services::Registry.validate_options!(type:, options: config)
          if Valpo::Services::Registry.managed_type?(type)
            validate_keys!(config, MANAGED_KEYS, "services.#{name}")
            normalized = {"type" => type, "version" => Valpo::Services::Registry.normalize_version(type, config["version"])}
          else
            validate_keys!(config, APP_KEYS, "services.#{name}")
            command = config.fetch("command", [])
            unless command.is_a?(Array) && command.all? { it.is_a?(String) && !it.empty? }
              raise Valpo::ValidationError, "services.#{name}.command must be an array of strings"
            end
            dependencies = config.fetch("depends_on", [])
            unless dependencies.is_a?(Array) && dependencies.all? { it.is_a?(String) && !it.empty? }
              raise Valpo::ValidationError, "services.#{name}.depends_on must be an array of service names"
            end
            port = config["port"]
            raise Valpo::ValidationError, "services.#{name}.port must be greater than 0" if port && (!port.is_a?(Integer) || port <= 0)
            healthcheck = optional_string(config, "healthcheck")
            raise Valpo::ValidationError, "services.#{name}.healthcheck must start with /" if healthcheck && !healthcheck.start_with?("/")
            normalized = {
              "type" => type,
              "build" => optional_string(config, "build"),
              "command" => command,
              "port" => port,
              "healthcheck" => healthcheck,
              "depends_on" => dependencies.uniq.sort
            }
          end
          [name, normalized]
        end
      end

      def validate_references!(manifest)
        sources = manifest.fetch("sources")
        builds = manifest.fetch("builds")
        services = manifest.fetch("services")
        builds.each do |name, build|
          raise Valpo::ValidationError, "builds.#{name} references unknown source #{build.fetch("source")}" unless sources.key?(build.fetch("source"))
        end
        services.each do |name, service|
          build = service["build"]
          raise Valpo::ValidationError, "services.#{name} references unknown build #{build}" if build && !builds.key?(build)
          service.fetch("depends_on", []).each do
            dependency = services[it]
            raise Valpo::ValidationError, "services.#{name} depends on unknown service #{it}" unless dependency
            unless Valpo::Services::Registry.managed_type?(dependency.fetch("type"))
              raise Valpo::ValidationError, "services.#{name} can only depend on managed services"
            end
          end
        end
      end

      def validate_keys!(hash, allowed, context)
        validate_table!(hash, context)
        unknown = hash.keys - allowed
        raise Valpo::ValidationError, "Unknown #{context} keys: #{unknown.sort.join(", ")}" unless unknown.empty?
      end

      def validate_table!(value, context)
        raise Valpo::ValidationError, "#{context} must be a table" unless value.is_a?(Hash)
      end

      def required_table(hash, key)
        value = hash[key]
        validate_table!(value, key)
        value
      end

      def required_string(hash, key)
        optional_string(hash, key) || raise(Valpo::ValidationError, "#{key} is required")
      end

      def optional_string(hash, key)
        value = hash[key]
        return nil if value.nil?
        raise Valpo::ValidationError, "#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?

        value
      end

      def optional_relative_path(hash, key)
        value = optional_string(hash, key)
        return nil unless value

        Valpo::Sources::Validation.relative_path(value, key:)
      end

      def boolean(hash, key, default)
        value = hash.fetch(key, default)
        raise Valpo::ValidationError, "#{key} must be true or false" unless value == true || value == false

        value
      end

      def validate_name!(value, context)
        return if value.to_s.match?(Valpo::Project::NAME_PATTERN)

        raise Valpo::ValidationError, "#{context} must use lowercase letters, numbers, and dashes"
      end
    end
  end
end
