# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class DeleteProject
        def initialize(orchestrator:)
          @orchestrator = orchestrator
        end

        def call(job, queue:)
          @orchestrator.delete_project(
            project_id: job.payload.fetch("project_id"), queue:, job_id: job[:id]
          )
        end
      end
    end
  end
end
