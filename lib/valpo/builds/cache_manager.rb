# frozen_string_literal: true

module Valpo
  module Builds
    class CacheManager
      def initialize(docker:)
        @docker = docker
      end

      def build_cache(build_target_id)
        "valpo-cnb-build-#{build_target_id}"
      end

      def launch_cache(build_target_id)
        "valpo-cnb-launch-#{build_target_id}"
      end

      def prepare(build_target_id:, queue:, job_id:)
        [build_cache(build_target_id), launch_cache(build_target_id)].each do
          result = docker.execute(docker.volume_create_command(it, labels: {"valpo.owned" => "true"}))
          next if result.fetch(:success)

          emit(result, queue:, job_id:)
          detail = result.fetch(:stderr).to_s.strip
          detail = result.fetch(:stdout).to_s.strip if detail.empty?
          raise Valpo::ValidationError, "Could not create build cache #{it}: #{detail}"
        end
      end

      def remove(build_target_id:, queue:, job_id:)
        [build_cache(build_target_id), launch_cache(build_target_id)].each do
          result = docker.execute(docker.volume_rm_command(it, force: true))
          next if result.fetch(:success) || missing_volume?(result)

          emit(result, queue:, job_id:)
          detail = result.fetch(:stderr).to_s.strip
          detail = result.fetch(:stdout).to_s.strip if detail.empty?
          raise Valpo::ValidationError, "Could not remove build cache #{it}: #{detail}"
        end
      end

      private

      attr_reader :docker

      def missing_volume?(result)
        stderr = result.fetch(:stderr).to_s
        stderr.include?("No such volume") || stderr.include?("No such object")
      end

      def emit(result, queue:, job_id:)
        queue.event(job_id, "stdout", result.fetch(:stdout)) unless result.fetch(:stdout).to_s.empty?
        queue.event(job_id, "stderr", result.fetch(:stderr)) unless result.fetch(:stderr).to_s.empty?
      end
    end
  end
end
