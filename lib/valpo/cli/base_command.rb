# frozen_string_literal: true

require "uri"

module Valpo
  module CLI
    class BaseCommand < Dry::CLI::Command
      option :api_url, default: ENV.fetch("VALPO_API_URL", DEFAULT_API_URL), desc: "Valpo API URL"
      option :config, default: ENV["VALPO_CONFIG"], desc: "Path to Valpo configuration"
      option :json, type: :boolean, default: false, desc: "Emit one JSON document"

      class << self
        def project_option
          option :project, aliases: ["-p"], desc: "Project name or ID (required with a service name)"
        end

        def wait_options
          option :wait, type: :boolean, default: true, desc: "Wait for the operation to finish"
          option :timeout, default: DEFAULT_TIMEOUT, desc: "Maximum wait in seconds"
        end
      end

      private

      def context(api_url:, config:, json:, **)
        @context ||= CLI.context_factory.call(api_url: api_url, config: config, json: json, out: @out, err: @err)
      rescue Valpo::API::Client::Error, Valpo::ValidationError => e
        raise OperationalError, e.message
      end

      def reject_extra_arguments!(args)
        return if args.nil? || args.empty?

        raise UsageError, "Unexpected arguments: #{args.join(" ")}"
      end

      def optional_positive_integer(value, name)
        return nil if value.nil? || value.to_s.empty?

        number = Integer(value, 10)
        raise UsageError, "#{name} must be greater than 0" unless number.positive?

        number
      rescue ArgumentError, TypeError
        raise UsageError, "#{name} must be an integer"
      end

      def required_option!(value, name)
        return value unless value.nil? || value.to_s.empty?

        raise UsageError, "#{name} is required"
      end

      def validate_service_options!(type:, options:)
        Valpo::Services::Definitions.validate_options!(type: type, options: options)
      rescue Valpo::ValidationError => e
        raise UsageError, e.message
      end

      def read_file(path)
        File.read(path)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise OperationalError, "Cannot read #{path}: #{e.message}"
      end

      def service_name(value)
        name = value.to_s
        raise UsageError, "Service names must not contain /; pass the project with --project" if name.include?("/")
        raise UsageError, "Service name is required" if name.empty?

        name
      end

      def parse_source_spec(value)
        provider, repository = value.to_s.split(":", 2)
        if provider.to_s.empty? || repository.to_s.empty?
          raise UsageError, "--source must use PROVIDER:OWNER/REPOSITORY"
        end

        {"provider" => provider.downcase, "repository" => repository}
      end

      def segment(value)
        URI.encode_www_form_component(value.to_s)
      end
    end
  end
end
