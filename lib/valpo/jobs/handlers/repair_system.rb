# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class RepairSystem
        def initialize(repairer:)
          @repairer = repairer
        end

        def call(job, queue:)
          @repairer.repair(queue:, job_id: job[:id])
        end
      end
    end
  end
end
