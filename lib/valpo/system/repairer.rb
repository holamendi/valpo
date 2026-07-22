# frozen_string_literal: true

module Valpo
  module System
    class Repairer
      def initialize(managed_lifecycle:, deployment_repairer:, caddy_reconciler:)
        @managed_lifecycle = managed_lifecycle
        @deployment_repairer = deployment_repairer
        @caddy_reconciler = caddy_reconciler
      end

      def repair(queue:, job_id:)
        queue.event(job_id, "system", "Repairing system state")
        managed_lifecycle.repair_services(queue:, job_id:)
        deployment_repairer.repair_services(queue:, job_id:)
        caddy_reconciler.apply(queue:, job_id:)
        true
      end

      private

      attr_reader :managed_lifecycle, :deployment_repairer, :caddy_reconciler
    end
  end
end
