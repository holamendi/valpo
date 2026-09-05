# frozen_string_literal: true

require "json"
require "digest"

module Valpo
  module Builds
    class BuildpackBuilder
      def initialize(client:, runner:, cache_manager:, builder:, timeout:, environment: nil)
        @client = client
        @runner = runner
        @cache_manager = cache_manager
        @builder = builder
        @timeout = timeout
        @environment = environment || BuildpackEnvironment.new(runner:)
      end

      def build(checkout:, build_target:, image:, service:, queue:, job_id:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        client.ensure_supported!
        if service.kind == "worker" && Valpo::AppServiceConfig[service.id].command.empty?
          raise Valpo::ValidationError, "Buildpack worker services require an explicit command"
        end

        selected = environment.prepare(builder: build_target.builder || builder, timeout:, queue:, job_id:)
        descriptor = File.join(checkout.context, "project.toml")
        descriptor_content = File.file?(descriptor) ? File.read(descriptor) : nil
        if build_target.buildpacks && descriptor_content
          queue.event(job_id, "system", "Explicit buildpacks override buildpack selection in project.toml")
        end
        fingerprint = Digest::SHA256.hexdigest(JSON.generate([selected, build_target.buildpacks, descriptor_content]))
        previous = Valpo::Release.where(build_target_id: build_target.id).order(Sequel.desc(:created_at)).first
        clear_cache = previous&.build_metadata&.fetch("cache_fingerprint", nil) != fingerprint
        cache_manager.prepare(build_target_id: build_target.id, queue:, job_id:)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Valpo::ValidationError, "Build timed out during preflight" unless remaining.positive?
        result = runner.run(
          client.build_command(
            image:,
            context: checkout.context,
            builder: selected.fetch("builder"),
            run_image: selected.fetch("run_image"),
            buildpacks: build_target.buildpacks,
            clear_cache:,
            build_cache: cache_manager.build_cache(build_target.id),
            launch_cache: cache_manager.launch_cache(build_target.id),
            default_process: (service.web? ? "web" : nil)
          ),
          timeout: remaining,
          queue:,
          job_id:
        )
        raise_build_error(result) unless result.fetch(:success)

        Result.new(
          image:,
          strategy: "buildpack",
          metadata: inspect_metadata(image, queue:, job_id:).merge(selected).merge("cache_fingerprint" => fingerprint)
        )
      end

      def initial_metadata(checkout: nil, build_target: nil)
        {"builder" => build_target&.builder || builder, "buildpacks" => [], "processes" => []}
      end

      private

      attr_reader :client, :runner, :cache_manager, :builder, :timeout, :environment

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
