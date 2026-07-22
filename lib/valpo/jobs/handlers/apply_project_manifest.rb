# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class ApplyProjectManifest
        def initialize(reconciler:)
          @reconciler = reconciler
        end

        def call(job, queue:)
          @reconciler.apply(job.payload.fetch("manifest"), queue:, job_id: job[:id])
        end
      end
    end
  end
end
