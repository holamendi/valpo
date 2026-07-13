# frozen_string_literal: true

require "tmpdir"

module Valpo
  module Builds
    class Orchestrator
      COMMIT_PATTERN = /\A[0-9a-f]{40,64}\z/i

      def initialize(docker:, source_fetcher:, deployment_orchestrator:)
        @docker = docker
        @source_fetcher = source_fetcher
        @deployment_orchestrator = deployment_orchestrator
      end

      def deploy_source(service_id:, ref:, internal_port:, healthcheck_path:, queue:, job_id:)
        service = find_app_service(service_id)
        app_config = Valpo::AppServiceConfig[service.id]
        build_target = app_config&.build_target
        raise Valpo::ValidationError, "Service has no configured build target" unless build_target

        source = build_target.source
        selected_ref = blank_to_nil(ref) || source.ref
        Dir.mktmpdir("valpo-build-") do |checkout|
          event(queue, job_id, "system", "Fetching #{source.repository}@#{selected_ref}")
          commit = fetch(source, checkout, selected_ref)
          dockerfile = checked_path(checkout, build_target.dockerfile, type: :file)
          context = checked_path(checkout, build_target.context, type: :directory)
          image = image_tag(service.project, build_target, commit)

          event(queue, job_id, "system", "Building #{image}")
          execute_build(dockerfile: dockerfile, context: context, image: image, queue: queue, job_id: job_id)
          deployment_orchestrator.deploy_built_image(
            service_id: service.id,
            image: image,
            source_ref: commit,
            build_target_id: build_target.id,
            internal_port: internal_port,
            healthcheck_path: healthcheck_path,
            queue: queue,
            job_id: job_id
          )
        end
      end

      private

      attr_reader :docker, :source_fetcher, :deployment_orchestrator

      def find_app_service(service_id)
        service = Valpo::Service[service_id]
        raise Valpo::ValidationError, "Service not found: #{service_id}" unless service
        raise Valpo::ValidationError, "Operation requires an app service" unless service.app?

        service
      end

      def fetch(source, checkout, ref)
        commit = source_fetcher.checkout(source: source, destination: checkout, ref: ref).to_s
        unless commit.match?(COMMIT_PATTERN)
          raise Valpo::ValidationError, "Git revision lookup returned an invalid commit SHA"
        end
        source.update(status: "connected") unless source.status == "connected"
        commit.downcase
      rescue
        source.update(status: "failed") unless source.status == "failed"
        raise
      end

      def checked_path(checkout, relative_path, type:)
        root = File.realpath(checkout)
        path = File.realpath(File.join(root, relative_path))
        unless path == root || path.start_with?("#{root}#{File::SEPARATOR}")
          raise Valpo::ValidationError, "Build path must stay within the source checkout: #{relative_path}"
        end
        valid_type = (type == :file) ? File.file?(path) : File.directory?(path)
        raise Valpo::ValidationError, "Build #{type} does not exist: #{relative_path}" unless valid_type

        path
      rescue Errno::ENOENT, Errno::EACCES
        raise Valpo::ValidationError, "Build #{type} does not exist: #{relative_path}"
      end

      def image_tag(project, build_target, commit)
        "valpo/#{project.name}/#{build_target.name}:#{commit[0, 12]}"
      end

      def execute_build(dockerfile:, context:, image:, queue:, job_id:)
        result = docker.execute(docker.build_command(dockerfile: dockerfile, tag: image, context: context))
        emit_result(result, queue: queue, job_id: job_id)
        return if result.fetch(:success)

        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "Docker build failed: #{detail}"
      end

      def emit_result(result, queue:, job_id:)
        stdout = result.fetch(:stdout).to_s.strip
        stderr = result.fetch(:stderr).to_s.strip
        event(queue, job_id, "stdout", stdout) unless stdout.empty?
        event(queue, job_id, "stderr", stderr) unless stderr.empty?
      end

      def event(queue, job_id, stream, message)
        queue.event(job_id, stream, message)
      end

      def blank_to_nil(value)
        (value.nil? || value.to_s.empty?) ? nil : value
      end
    end
  end
end
