# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class ApplyCaddyConfig
        def initialize(reconciler:)
          @reconciler = reconciler
        end

        def call(job, queue:)
          @reconciler.apply(queue:, job_id: job[:id])
        end
      end
    end
  end
end
