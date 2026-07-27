# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Storage
    class ContainerCleaner
      def initialize(docker:, grace_period:, clock: -> { Time.now.utc })
        @docker = docker
        @grace_period = grace_period
        @clock = clock
      end

      def call(dry_run:, queue:, job_id:)
        protected_names = protected_container_names
        removed = 0
        owned_containers.each do
          name = it["Names"].to_s
          next if name.empty? || protected_names.include?(name)
          next unless older_than_grace?(it["CreatedAt"])

          if dry_run
            queue.event(job_id, "system", "Would remove orphaned container #{name}")
          else
            result = docker.execute(docker.rm_command(name, force: true))
            unless result.fetch(:success) || missing_container?(result)
              queue.event(job_id, "stderr", "Could not remove orphaned container #{name}: #{detail(result)}")
              next
            end
            clear_stale_release_reference(name)
            queue.event(job_id, "system", "Removed orphaned container #{name}")
          end
          removed += 1
        end
        {orphaned_containers: removed}
      end

      private

      attr_reader :docker, :grace_period, :clock

      def protected_container_names
        release_names = Valpo::Release.where(status: %w[pending ready active])
          .exclude(container_name: nil)
          .select_map(:container_name)
        managed_names = Valpo::ManagedServiceConfig.exclude(container_name: nil).select_map(:container_name)
        (release_names + managed_names).to_set
      end

      def owned_containers
        result = docker.execute(
          docker.container_list_command(all: true, filters: ["label=valpo.owned=true"])
        )
        unless result.fetch(:success)
          raise Valpo::ValidationError, "Could not list Docker containers: #{detail(result)}"
        end

        result.fetch(:stdout).lines.filter_map do
          next if it.strip.empty?

          JSON.parse(it)
        end
      rescue JSON::ParserError => e
        raise Valpo::ValidationError, "Docker container list returned invalid JSON: #{e.message}"
      end

      def older_than_grace?(value)
        Time.parse(value.to_s) < clock.call - grace_period
      rescue ArgumentError
        false
      end

      def clear_stale_release_reference(name)
        Valpo::Release.where(container_name: name)
          .exclude(status: %w[pending ready active])
          .update(container_name: nil, route_target: nil)
      end

      def missing_container?(result)
        result.fetch(:stderr).to_s.match?(/No such container|No such object/i)
      end

      def detail(result)
        result.fetch(:stderr).to_s.strip.then { it.empty? ? result.fetch(:stdout).to_s.strip : it }
      end
    end
  end
end
