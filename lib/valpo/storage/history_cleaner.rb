# frozen_string_literal: true

module Valpo
  module Storage
    class HistoryCleaner
      def initialize(retention:, clock: -> { Time.now.utc })
        @retention = retention
        @clock = clock
      end

      def call(dry_run:, queue:, job_id:)
        cutoff = clock.call - retention
        jobs = Valpo::Job.where(status: %w[succeeded failed]).where { finished_at < cutoff }
        deliveries = Valpo::GitHubWebhookDelivery.where { created_at < cutoff }
        counts = {
          jobs: jobs.count,
          job_events: Valpo::JobEvent.where(job_id: jobs.select(:id)).count,
          github_webhook_deliveries: deliveries.count
        }

        unless dry_run
          jobs.delete
          deliveries.delete
          Valpo::Database.connection.run("PRAGMA incremental_vacuum")
        end
        action = dry_run ? "Would remove" : "Removed"
        queue.event(
          job_id,
          "system",
          "#{action} #{counts.fetch(:jobs)} jobs, #{counts.fetch(:job_events)} job events, " \
            "and #{counts.fetch(:github_webhook_deliveries)} GitHub webhook deliveries"
        )
        counts
      end

      private

      attr_reader :retention, :clock
    end
  end
end
