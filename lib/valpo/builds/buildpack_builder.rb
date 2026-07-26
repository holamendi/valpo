# frozen_string_literal: true

require "json"

module Valpo
  module Builds
    class BuildpackBuilder
      def initialize(client:, runner:, cache_manager:, builder:, timeout:)
        @client = client
        @runner = runner
        @cache_manager = cache_manager
        @builder = builder
        @timeout = timeout
      end

      def build(checkout:, build_target:, image:, service:, queue:, job_id:)
        client.ensure_supported!
        if service.kind == "worker" && Valpo::AppServiceConfig[service.id].command.empty?
          raise Valpo::ValidationError, "Buildpack worker services require an explicit command"
        end

        cache_manager.prepare(build_target_id: build_target.id, queue:, job_id:)
        result = runner.run(
          client.build_command(
            image:,
            context: checkout.context,
            builder:,
            build_cache: cache_manager.build_cache(build_target.id),
            launch_cache: cache_manager.launch_cache(build_target.id),
            default_process: (service.web? ? "web" : nil)
          ),
          timeout:,
          queue:,
          job_id:
        )
        raise_build_error(result) unless result.fetch(:success)

        Result.new(
          image:,
          strategy: "buildpack",
          metadata: inspect_metadata(image, queue:, job_id:)
        )
      end

      def initial_metadata(checkout: nil)
        {"builder" => builder, "buildpacks" => [], "processes" => []}
      end

      private

      attr_reader :client, :runner, :cache_manager, :builder, :timeout

      def inspect_metadata(image, queue:, job_id:)
        result = client.inspect(image)
        unless result.fetch(:success)
          detail = result.fetch(:stderr).to_s.strip
          queue.event(job_id, "system", "Warning: could not inspect buildpack metadata#{": #{detail}" unless detail.empty?}")
          return initial_metadata
        end

        document = JSON.parse(result.fetch(:stdout))
        {
          "builder" => builder,
          "buildpacks" => entries(document, "buildpacks").filter_map { buildpack_metadata(it) },
          "processes" => entries(document, "processes").filter_map { process_metadata(it) }
        }
      rescue JSON::ParserError
        queue.event(job_id, "system", "Warning: pack inspect returned invalid JSON")
        initial_metadata
      end

      def entries(value, key)
        return value.fetch(key) if value.is_a?(Hash) && value[key].is_a?(Array)

        return [] unless value.is_a?(Hash)

        info = value["local_info"] || value["remote_info"]
        (info.is_a?(Hash) && info[key].is_a?(Array)) ? info.fetch(key) : []
      end

      def buildpack_metadata(value)
        return unless value.is_a?(Hash)

        id = value["id"] || value["ID"]
        return if id.to_s.empty?

        {"id" => id.to_s, "version" => (value["version"] || value["Version"]).to_s}
      end

      def process_metadata(value)
        return unless value.is_a?(Hash)

        type = value["type"] || value["Type"]
        return if type.to_s.empty?

        default = if value.key?("default")
          value["default"]
        elsif value.key?("Default")
          value["Default"]
        else
          type == "web"
        end
        {"type" => type.to_s, "default" => !!default}
      end

      def raise_build_error(result)
        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "Buildpack build failed: #{detail}"
      end
    end
  end
end
