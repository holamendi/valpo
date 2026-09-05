# frozen_string_literal: true

require "open3"
require "rbconfig"

module Valpo
  module Builds
    class BuildpackClient
      SUPPORTED_ARCHITECTURES = {
        "aarch64" => "arm64",
        "arm64" => "arm64",
        "x86_64" => "amd64"
      }.freeze

      def initialize(binary: "pack", platform: RUBY_PLATFORM, host_cpu: RbConfig::CONFIG.fetch("host_cpu"))
        @binary = binary
        @platform = platform
        @host_cpu = host_cpu
      end

      def ensure_supported!
        return if platform.include?("linux") && SUPPORTED_ARCHITECTURES.key?(host_cpu)

        raise Valpo::ValidationError, "Buildpack builds require Linux on amd64 or arm64; use a Dockerfile on this host"
      end

      def build_command(image:, context:, builder:, build_cache:, launch_cache:, default_process:, buildpacks: nil, run_image: nil, clear_cache: false)
        arguments = [
          "--no-color",
          "build",
          image,
          "--path",
          context,
          "--builder",
          builder,
          "--pull-policy",
          "if-not-present"
        ]
        arguments += ["--run-image", run_image] if run_image
        arguments << "--clear-cache" if clear_cache
        buildpacks&.each { arguments += ["--buildpack", it] }
        arguments += ["--default-process", default_process] if default_process
        arguments += [
          "--cache",
          "type=build;format=volume;name=#{build_cache};type=launch;format=volume;name=#{launch_cache}"
        ]
        command(*arguments)
      end

      def inspect(image)
        stdout, stderr, status = Open3.capture3(*command("inspect", image, "--output", "json"))
        {stdout:, stderr:, status: status.exitstatus, success: status.success?}
      rescue Errno::ENOENT => e
        {stdout: "", stderr: e.message, status: 127, success: false}
      end

      private

      attr_reader :binary, :platform, :host_cpu

      def command(*arguments)
        [binary, *arguments]
      end
    end
  end
end
