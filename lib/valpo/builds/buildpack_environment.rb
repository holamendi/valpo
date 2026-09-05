# frozen_string_literal: true

require "json"
require "tmpdir"
require "securerandom"

module Valpo
  module Builds
    # Resolve immutable inputs before detection and repair Docker's incomplete
    # containerd image content before the lifecycle tries to export an image.
    class BuildpackEnvironment
      class QuietQueue
        def event(*)
        end
      end

      def initialize(runner:)
        @runner = runner
      end

      def prepare(builder:, timeout:, queue:, job_id:)
        @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @queue, @job_id = queue, job_id
        execute(["docker", "buildx", "version"])
        execute(["pack", "version"])
        platform = execute(["docker", "version", "--format", "{{.Server.Os}}/{{.Server.Arch}}"], quiet: true).strip
        unless %w[linux/amd64 linux/arm64].include?(platform)
          raise Valpo::ValidationError, "Buildpacks require a Linux amd64 or arm64 Docker daemon; got #{platform}"
        end
        builder = resolve(builder, platform)
        metadata = JSON.parse(execute(["docker", "image", "inspect", "--format", '{{ index .Config.Labels "io.buildpacks.builder.metadata" }}', builder], quiet: true))
        run_image = metadata.dig("stack", "runImage", "image") || metadata.dig("runImages", 0, "image")
        raise Valpo::ValidationError, "Builder does not declare a run image" unless run_image

        Valpo::Builds::BuildpackOptions.validate!(strategy: "buildpack", builder: run_image, buildpacks: nil)
        run_image = resolve(run_image, platform)
        driver = execute(["docker", "info", "--format", "{{json .DriverStatus}}"], quiet: true)
        if driver.include?("io.containerd.snapshotter")
          export = ["sh", "-c", 'exec docker image save --platform "$1" "$2" > /dev/null', "valpo-export", platform, run_image]
          result = run(export, quiet: true)
          unless result.fetch(:success)
            unless (result[:stderr].to_s + result[:stdout].to_s).include?("no suitable export target")
              raise Valpo::ValidationError, "Run-image export preflight failed: #{result[:stderr]}"
            end
            queue.event(job_id, "system", "Preparing run-image layers for Docker containerd export")
            materialize(run_image, platform)
            execute(export, quiet: true)
          end
        end
        {"builder" => builder, "run_image" => run_image, "platform" => platform}
      rescue JSON::ParserError
        raise Valpo::ValidationError, "Docker returned invalid buildpack builder metadata"
      end

      private

      def resolve(reference, platform)
        execute(["docker", "pull", "--platform", platform, reference])
        digests = JSON.parse(execute(["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", reference], quiet: true))
        digest = reference.include?("@sha256:") ? reference : digests&.first
        raise Valpo::ValidationError, "Could not resolve immutable image digest for #{reference}" unless digest

        digest
      end

      def materialize(reference, platform)
        tag = "valpo-runtime-preflight:#{SecureRandom.hex(8)}"
        Dir.mktmpdir("valpo-runtime-preflight") do
          File.write(File.join(it, "Dockerfile"), "FROM #{reference}\n")
          execute(["docker", "buildx", "build", "--builder", "default", "--load", "--platform", platform, "--tag", tag, it])
        end
      ensure
        cleanup_tag(tag) if tag
      end

      def cleanup_tag(tag)
        @runner.run(["docker", "image", "rm", tag], timeout: 10, queue: QuietQueue.new, job_id: @job_id)
      rescue Valpo::ValidationError
        # Cleanup must not replace the original build/timeout error.
        nil
      end

      def run(command, quiet: false)
        remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Valpo::ValidationError, "Buildpack preflight timed out" unless remaining.positive?

        @runner.run(command, timeout: remaining, queue: quiet ? QuietQueue.new : @queue, job_id: @job_id)
      end

      def execute(command, quiet: false)
        result = run(command, quiet:)
        unless result.fetch(:success)
          raise Valpo::ValidationError, "Buildpack preflight failed (#{command.take(3).join(" ")}): #{result[:stderr]}"
        end
        result.fetch(:stdout)
      end
    end
  end
end
