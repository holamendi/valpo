# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class ReconcileEnvironment
        def initialize(manager:)
          @manager = manager
        end

        def call(job, queue:)
          manager.reconcile(
            service_id: job.payload.fetch("service_id"),
            queue:,
            job_id: job.id
          )
        end

        private

        attr_reader :manager
      end
    end
  end
end
