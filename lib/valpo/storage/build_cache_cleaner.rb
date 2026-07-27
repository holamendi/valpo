# frozen_string_literal: true

module Valpo
  module Storage
    class BuildCacheCleaner
      def initialize(docker:, cache_manager:, retention:, clock: -> { Time.now.utc })
        @docker = docker
        @cache_manager = cache_manager
        @retention = retention
        @clock = clock
      end

      def call(dry_run:, queue:, job_id:)
        volumes = cache_volumes
        removed = 0
        stale_targets.each do
          names = cache_names(it.id)
          existing = names.select { volumes.include?(it) }
          next if existing.empty?

          if dry_run
            queue.event(job_id, "system", "Would remove stale build cache for #{it.name}")
          else
            cache_manager.remove(build_target_id: it.id, queue:, job_id:)
            queue.event(job_id, "system", "Removed stale build cache for #{it.name}")
          end
          removed += existing.length
        rescue => e
          queue.event(job_id, "stderr", "Could not remove build cache for #{it.name}: #{e.message}")
        end
        {build_cache_volumes: removed}
      end

      private

      attr_reader :docker, :cache_manager, :retention, :clock

      def cache_volumes
        result = docker.execute(docker.volume_list_command(filters: ["label=valpo.owned=true"]))
        unless result.fetch(:success)
          detail = result.fetch(:stderr).to_s.strip
          raise Valpo::ValidationError, "Could not list Docker volumes: #{detail}"
        end

        result.fetch(:stdout).lines.map(&:strip).select { it.start_with?("valpo-cnb-build-", "valpo-cnb-launch-") }.to_set
      end

      def stale_targets
        cutoff = clock.call - retention
        Valpo::BuildTarget.all.select do
          last_release = Valpo::Release.where(build_target_id: it.id).max(:created_at)
          (last_release || it.created_at) < cutoff
        end
      end

      def cache_names(build_target_id)
        [
          cache_manager.build_cache(build_target_id),
          cache_manager.launch_cache(build_target_id)
        ]
      end
    end
  end
end
