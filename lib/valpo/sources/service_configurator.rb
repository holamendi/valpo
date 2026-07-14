# frozen_string_literal: true

module Valpo
  module Sources
    class ServiceConfigurator
      DEFAULT_REF = "HEAD"
      DEFAULT_DOCKERFILE = "Dockerfile"
      DEFAULT_CONTEXT = "."

      def normalize_create(source:, build:)
        validate_keys!(source, %w[provider repository ref], "source")
        validate_keys!(build || {}, %w[dockerfile context], "build")
        {
          source: normalize_source(source, fallback: nil),
          build: normalize_build(build, fallback: nil)
        }
      end

      def desired_for(service:, source_changes:, build_changes:)
        validate_keys!(source_changes || {}, %w[provider repository ref], "source")
        validate_keys!(build_changes || {}, %w[dockerfile context], "build")
        current_build = Valpo::AppServiceConfig[service.id]&.build_target
        current_source = current_build&.source
        {
          source: normalize_source(source_changes, fallback: current_source && source_attributes(current_source)),
          build: normalize_build(build_changes, fallback: current_build && build_attributes(current_build))
        }
      end

      def create_service!(project:, service_attributes:, source:, build:)
        Valpo::Database.connection.transaction do
          service = Valpo::Services::Catalog.create_service(
            project_id: project.id,
            name: service_attributes.fetch("name"),
            type: service_attributes.fetch("type"),
            command: service_attributes.fetch("command", []),
            internal_port: service_attributes["internal_port"],
            healthcheck_path: service_attributes["healthcheck_path"]
          )
          source_record = Valpo::Source.create(
            project_id: project.id,
            owner_service_id: service.id,
            name: available_name(Valpo::Source, project.id, service.name),
            provider: source.fetch("provider"),
            repository: source.fetch("repository"),
            ref: source.fetch("ref"),
            auto_deploy: false,
            status: "connected"
          )
          build_record = Valpo::BuildTarget.create(
            project_id: project.id,
            owner_service_id: service.id,
            source_id: source_record.id,
            name: available_name(Valpo::BuildTarget, project.id, service.name),
            dockerfile: build.fetch("dockerfile"),
            context: build.fetch("context")
          )
          Valpo::AppServiceConfig[service.id].update(build_target_id: build_record.id)
          service.refresh
        end
      end

      def apply_owned_configuration!(service:, source:, build:)
        Valpo::Database.connection.transaction do
          source_record = Valpo::Source.where(owner_service_id: service.id).first
          if source_record
            source_record.update(
              provider: source.fetch("provider"),
              repository: source.fetch("repository"),
              ref: source.fetch("ref"),
              status: "connected"
            )
          else
            source_record = Valpo::Source.create(
              project_id: service.project_id,
              owner_service_id: service.id,
              name: available_name(Valpo::Source, service.project_id, service.name),
              provider: source.fetch("provider"),
              repository: source.fetch("repository"),
              ref: source.fetch("ref"),
              auto_deploy: false,
              status: "connected"
            )
          end

          build_record = Valpo::BuildTarget.where(owner_service_id: service.id).first
          if build_record
            build_record.update(
              source_id: source_record.id,
              dockerfile: build.fetch("dockerfile"),
              context: build.fetch("context")
            )
          else
            build_record = Valpo::BuildTarget.create(
              project_id: service.project_id,
              owner_service_id: service.id,
              source_id: source_record.id,
              name: available_name(Valpo::BuildTarget, service.project_id, service.name),
              dockerfile: build.fetch("dockerfile"),
              context: build.fetch("context")
            )
          end
          Valpo::AppServiceConfig[service.id].update(build_target_id: build_record.id)
          build_record.refresh
        end
      end

      private

      def normalize_source(input, fallback:)
        values = fallback ? fallback.merge(stringify_keys(input || {})) : stringify_keys(input || {})
        provider = required(values, "provider").downcase
        repository = required(values, "repository")
        ref = optional(values, "ref") || DEFAULT_REF
        unless Valpo::Source::PROVIDERS.include?(provider)
          raise Valpo::ValidationError, "Unsupported source provider: #{provider}"
        end
        if provider == "github" && !repository.match?(Valpo::Sources::GitHub::REPOSITORY_PATTERN)
          raise Valpo::ValidationError, "GitHub repository must be an owner/repository name"
        end
        unless ref.match?(Valpo::Sources::GitHub::REF_PATTERN)
          raise Valpo::ValidationError, "GitHub ref must be a branch, tag, or commit SHA without whitespace"
        end

        {"provider" => provider, "repository" => repository, "ref" => ref}
      end

      def normalize_build(input, fallback:)
        values = fallback ? fallback.merge(stringify_keys(input || {})) : stringify_keys(input || {})
        {
          "dockerfile" => optional(values, "dockerfile") || DEFAULT_DOCKERFILE,
          "context" => optional(values, "context") || DEFAULT_CONTEXT
        }
      end

      def source_attributes(source)
        {"provider" => source.provider, "repository" => source.repository, "ref" => source.ref}
      end

      def build_attributes(build)
        {"dockerfile" => build.dockerfile, "context" => build.context}
      end

      def stringify_keys(value)
        raise Valpo::ValidationError, "source and build configuration must be objects" unless value.is_a?(Hash)

        value.to_h { |key, entry| [key.to_s, entry] }
      end

      def validate_keys!(value, allowed, context)
        keys = stringify_keys(value).keys
        unknown = keys - allowed
        return if unknown.empty?

        raise Valpo::ValidationError, "Unknown #{context} keys: #{unknown.sort.join(", ")}"
      end

      def required(values, key)
        optional(values, key) || raise(Valpo::ValidationError, "#{key} is required")
      end

      def optional(values, key)
        value = values[key]
        return nil if value.nil?
        raise Valpo::ValidationError, "#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?

        value
      end

      def available_name(model, project_id, base)
        candidates = [base, "#{base}-cli"] + (2..100).map { |number| "#{base}-cli-#{number}" }
        candidates.find { |name| model.where(project_id: project_id, name: name).empty? } ||
          raise(Valpo::ConflictError, "No source configuration name is available for #{base}")
      end
    end
  end
end
