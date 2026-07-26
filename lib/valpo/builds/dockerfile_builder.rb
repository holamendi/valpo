# frozen_string_literal: true

module Valpo
  module Builds
    class DockerfileBuilder
      def initialize(docker:, runner:, timeout:)
        @docker = docker
        @runner = runner
        @timeout = timeout
      end

      def build(checkout:, image:, queue:, job_id:, **)
        result = runner.run(
          docker.build_command(dockerfile: checkout.dockerfile, tag: image, context: checkout.context),
          timeout:,
          queue:,
          job_id:
        )
        raise_build_error(result) unless result.fetch(:success)

        Result.new(
          image:,
          strategy: "dockerfile",
          metadata: initial_metadata(checkout:)
        )
      end

      def initial_metadata(checkout:)
        {"dockerfile" => relative_dockerfile(checkout)}
      end

      private

      attr_reader :docker, :runner, :timeout

      def relative_dockerfile(checkout)
        Pathname.new(checkout.dockerfile).relative_path_from(Pathname.new(checkout.checkout)).to_s
      end

      def raise_build_error(result)
        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "Docker build failed: #{detail}"
      end
    end
  end
end
